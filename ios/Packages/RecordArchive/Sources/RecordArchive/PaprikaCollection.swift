import Foundation
import zlib

/// Paprika's collection format is a ZIP of gzip-compressed recipe JSON files.
/// Read members in memory. Archive paths never become filesystem destinations.
public enum PaprikaCollection {
    public static let maximumCollectionBytes = 32 * 1_048_576
    private static let memberLimit = ArchiveCodec.maximumNativeBytes
    private static let libraryLimit = ArchiveCodec.maximumFileBytes * 4

    private static let sourcePrefix = "paprika-v1/"
    public static func isTracked(_ record: ArchiveRecord) -> Bool {
        record.origin == "recipe-library-v1" && record.kind == .recipe &&
        record.id.hasPrefix(sourcePrefix) && ArchiveCodec.validProjectionDigest(String(record.id.dropFirst(sourcePrefix.count)))
    }

    /// For a local edit, remember which incoming revision it corrected even after further edits.
    public static func correctedRecord(_ recipe: ImportedRecipe, previous: ArchiveRecord) throws -> ArchiveRecord {
        var recipe = recipe
        if let bytes = previous.nativePayload {
            let prior = try JSONDecoder().decode(ImportedRecipe.self, from: bytes)
            if recipe.filing == nil { recipe.filing = prior.filing }
            recipe.paprikaLegacyRevision = prior.paprikaLegacyRevision
        }
        var updated = try recipe.archiveRecord(origin: previous.origin, savedAt: Date(timeIntervalSince1970: 0))
        updated.id = previous.id
        let original = isTracked(previous) || recipe.filing != nil ? previous.parentRevision ?? previous.revision : previous.id
        updated.parentRevision = updated.revision == original ? nil : original
        return updated
    }

    /// An older content-only import cannot establish ownership of a UID. Let the shopper decide
    /// whether this matching older copy is sufficient before recording a separate tracked version.
    public static func legacyMatches(_ records: [ArchiveRecord], saved: [ArchiveRecord]) -> Set<String> {
        let existing = saved.filter { $0.kind == .recipe && $0.origin == "recipe-library-v1" && $0.nativePayload != nil && !isTracked($0) }
        let revisions = Set(existing.flatMap { [$0.id, $0.revision] })
        return Set(records.filter { isTracked($0) && !revisions.isDisjoint(with: legacyContentRevisions($0)) }.map(\.id))
    }

    static func legacyContentRevisions(_ record: ArchiveRecord) -> [String] {
        var revisions = [record.revision, record.parentRevision].compactMap { $0 }
        if let data = record.nativePayload, let recipe = try? JSONDecoder().decode(ImportedRecipe.self, from: data),
           recipe.filing != nil {
            revisions.append(recipe.paprikaLegacyRevision ?? recipe.contentBeforeFiling)
            return revisions
        }
        return isTracked(record) ? revisions : []
    }

    /// One reviewed mapping applies to all eligible recipes in this batch. Keep source labels for later repair.
    public static func mapCategory(_ source: String, to category: String?, in record: ArchiveRecord) throws -> ArchiveRecord {
        guard ImportedRecipe.Filing.valid(source), category.map(ImportedRecipe.Filing.valid) ?? true,
              record.kind == .recipe, let data = record.nativePayload else { throw ArchiveError.invalidRecipe }
        var recipe = try JSONDecoder().decode(ImportedRecipe.self, from: data).validated()
        guard let index = recipe.filing?.firstIndex(where: { $0.source == source }),
              recipe.filing?[index].category != category else { return record }
        recipe.filing?[index].category = category
        return try correctedRecord(recipe, previous: record)
    }

    private struct Version: Hashable {
        let source: String
        let revision: String
    }

    private struct Known {
        var allContent: Set<String> = []
        var versions: Set<Version> = []
    }

    public static func stage(_ data: Data, existing: [ImportedRecipe] = [],
                             existingSourceIDs: Set<String> = []) throws -> RecipeImportReport {
        let legacy = existingSourceIDs.union(existing.map(\.id))
        let staged = try read(data, known: Known(allContent: legacy)).report
        let recipes = staged.recipes.filter { !legacy.contains($0.id) }
        return RecipeImportReport(recipes: recipes, duplicateCount: staged.duplicateCount + staged.recipes.count - recipes.count,
                                  skippedRows: staged.skippedRows, unsupportedFields: staged.unsupportedFields)
    }

    /// Unkeyed recipes and older Paprika imports retain their original content-addressed archive identities.
    public static func stageRecords(_ data: Data, saved: [ArchiveRecord]) throws -> (report: RecipeImportReport, records: [ArchiveRecord]) {
        var known = Known()
        for record in saved where record.kind == .recipe {
            guard let bytes = record.nativePayload, let recipe = try? JSONDecoder().decode(ImportedRecipe.self, from: bytes) else { continue }
            let content = recipe.id
            known.allContent.insert(content)
            if isTracked(record) {
                known.versions.insert(Version(source: record.id, revision: content))
                if let imported = record.parentRevision { known.versions.insert(Version(source: record.id, revision: imported)) }
            } else {
                if recipe.filing != nil, let original = record.parentRevision {
                    known.versions.insert(Version(source: record.id, revision: original))
                }
                if record.origin == "recipe-library-v1", record.parentRevision == record.id, content == record.revision {
                    known.allContent.insert(record.id)
                }
            }
        }
        return try read(data, known: known)
    }

    private static func read(_ data: Data, known: Known) throws -> (report: RecipeImportReport, records: [ArchiveRecord]) {
        guard data.count <= maximumCollectionBytes else { throw ArchiveError.tooLarge }
        let archive = Bytes(data: Data(data))
        let end = try archive.directoryEnd()
        let count = try archive.short(end + 10)
        guard count <= 2 * ArchiveCodec.maximumRecords + 16 else { throw ArchiveError.tooLarge }
        let start = try archive.long(end + 16)
        guard try start + archive.long(end + 12) == end,
              try archive.short(end + 4) == 0, try archive.short(end + 6) == 0,
              try archive.short(end + 8) == count else { throw ArchiveError.malformed }

        var cursor = start, decodedBytes = 0, memberBytes = 0, recipeEntries = 0
        var recipes: [ImportedRecipe] = [], skipped = 0, duplicates = 0
        var known = known
        var records: [ArchiveRecord] = []
        var unsupported = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            let member = try archive.member(at: cursor, directory: start)
            cursor = member.next
            if member.name.hasSuffix("/") || member.name.hasPrefix("__MACOSX/") || member.name.split(separator: "/").last == ".DS_Store" { continue }
            let name = member.name.lowercased()
            guard name.hasSuffix(".paprikarecipe") || name.hasSuffix(".json") else { skipped += 1; continue }
            recipeEntries += 1
            guard recipeEntries <= ArchiveCodec.maximumRecords else { throw ArchiveError.tooLarge }
            memberBytes += member.expanded
            guard member.expanded <= memberLimit, memberBytes <= libraryLimit else { throw ArchiveError.tooLarge }
            let payload = try archive.slice(member.body, count: member.compressed)
            let gzip = member.method == 0 ? payload : try inflateBytes(payload, window: -MAX_WBITS, limit: member.expanded)
            guard gzip.count == member.expanded, gzip.withUnsafeBytes({ buffer in
                crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
            }) == uLong(member.crc) else { throw ArchiveError.malformed }
            let json = try inflateBytes(gzip, window: MAX_WBITS + 16, limit: min(memberLimit, libraryLimit - decodedBytes))
            decodedBytes += json.count
            try ArchiveCodec.preflight(json, maximum: memberLimit)
            guard let fields = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let recipe = readRecipe(fields, unsupported: &unsupported) else { skipped += 1; continue }
            let revision = recipe.id
            var record = try recipe.archiveRecord(origin: "recipe-library-v1", savedAt: Date(timeIntervalSince1970: 0))
            if let uid = fields["uid"] as? String, !uid.isEmpty, uid.utf8.count <= 512, !uid.contains("\0") {
                let normalized = UUID(uuidString: uid)?.uuidString.lowercased() ?? uid
                record.id = sourcePrefix + ArchiveCodec.digest(Data(normalized.utf8))
                let version = Version(source: record.id, revision: revision)
                guard known.versions.insert(version).inserted else { duplicates += 1; continue }
            } else {
                record.id = recipe.contentBeforeFiling
                guard !known.allContent.contains(revision),
                      !known.versions.contains(Version(source: record.id, revision: revision)) else { duplicates += 1; continue }
            }
            known.allContent.insert(revision)
            recipes.append(recipe)
            records.append(record)
        }
        guard cursor == end else { throw ArchiveError.malformed }
        guard !recipes.isEmpty || duplicates > 0 else { throw ArchiveError.invalidRecipe }
        return (RecipeImportReport(recipes: recipes, duplicateCount: duplicates, skippedRows: skipped,
                                   unsupportedFields: unsupported.sorted()), records)
    }

    private static func readRecipe(_ fields: [String: Any], unsupported: inout Set<String>) -> ImportedRecipe? {
        let mapped = ["name", "servings", "ingredients", "directions", "source_url", "source", "notes"]
        for (key, value) in fields where key != "uid" && key != "categories" && !mapped.contains(key) && !(value is NSNull) {
            unsupported.insert(String(key.prefix(80)))
        }
        guard let title = fields["name"] as? String,
              mapped.allSatisfy({ fields[$0] == nil || fields[$0] is String || fields[$0] is NSNull }) else { return nil }
        func value(_ key: String) -> String { fields[key] as? String ?? "" }
        func lines(_ key: String) -> [String] {
            value(key).components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let source = value("source_url").trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = [value("source"), value("notes")].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var recipe = ImportedRecipe(title: title, yieldText: value("servings"), ingredients: lines("ingredients"),
                                    steps: lines("directions"), sourceURL: source.isEmpty ? nil : source, notes: notes)
        if let input = fields["categories"], !(input is NSNull) {
            if let values = input as? [Any], values.count <= 64 {
                let labels = values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter(ImportedRecipe.Filing.valid)
                if labels.count != values.count { unsupported.insert("categories") }
                if !labels.isEmpty {
                    let legacyRevision = recipe.id
                    recipe.filing = Set(labels).sorted().map { .init(source: $0, category: $0) }
                    recipe.paprikaLegacyRevision = legacyRevision
                }
            } else { unsupported.insert("categories") }
        }
        guard recipe.ingredients.allSatisfy({ $0.utf8.count <= ArchiveCodec.maximumHelperFieldBytes }),
              (try? recipe.validated()) != nil,
              let payload = try? ArchiveCodec.canonical(recipe), payload.count <= memberLimit else { return nil }
        return recipe
    }

    private static func inflateBytes(_ data: Data, window: Int32, limit: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, window, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw ArchiveError.unavailable }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data(), chunk = [UInt8](repeating: 0, count: 32_768)
            repeat {
                try Task.checkCancellation()
                let status = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk.count - Int(stream.avail_out)
                guard produced <= limit - output.count else { throw ArchiveError.tooLarge }
                output.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw ArchiveError.malformed }
                    return output
                }
                guard status == Z_OK, produced > 0 else { throw ArchiveError.malformed }
            } while true
        }
    }

    private struct Member {
        let name: String
        let next, body, method, compressed, expanded, crc: Int
    }

    private struct Bytes {
        let data: Data
        func short(_ i: Int) throws -> Int {
            guard i >= 0, i + 2 <= data.count else { throw ArchiveError.malformed }
            return Int(data[i]) | Int(data[i + 1]) << 8
        }
        func long(_ i: Int) throws -> Int { try short(i) | short(i + 2) << 16 }
        func slice(_ i: Int, count: Int) throws -> Data {
            guard i >= 0, i + count <= data.count else { throw ArchiveError.malformed }
            return data.subdata(in: i..<(i + count))
        }
        func directoryEnd() throws -> Int {
            guard data.count >= 22 else { throw ArchiveError.malformed }
            for i in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
            where data[i] == 0x50 {
                if try long(i) == 0x06054b50, try i + 22 + short(i + 20) == data.count { return i }
            }
            throw ArchiveError.malformed
        }
        func member(at i: Int, directory: Int) throws -> Member {
            guard try long(i) == 0x02014b50, try short(i + 34) == 0 else { throw ArchiveError.malformed }
            let flags = try short(i + 8), method = try short(i + 10)
            guard flags & ~0x080E == 0, [0, 8].contains(method) else { throw ArchiveError.unsupportedVersion }
            let compressed = try long(i + 20), expanded = try long(i + 24), crc = try long(i + 16)
            let nameBytes = try slice(i + 46, count: short(i + 28))
            guard let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1)
            else { throw ArchiveError.malformed }
            let next = try i + 46 + nameBytes.count + short(i + 30) + short(i + 32)
            let local = try long(i + 42)
            guard try long(local) == 0x04034b50, try short(local + 6) == flags,
                  try short(local + 8) == method, try short(local + 26) == nameBytes.count,
                  try slice(local + 30, count: nameBytes.count) == nameBytes else { throw ArchiveError.malformed }
            let body = try local + 30 + nameBytes.count + short(local + 28)
            guard body + compressed <= directory, method != 0 || compressed == expanded else { throw ArchiveError.malformed }
            if flags & 8 == 0 {
                guard try long(local + 18) == compressed, try long(local + 22) == expanded,
                      try long(local + 14) == crc else { throw ArchiveError.malformed }
            }
            return Member(name: name, next: next, body: body, method: method, compressed: compressed, expanded: expanded, crc: crc)
        }
    }
}
