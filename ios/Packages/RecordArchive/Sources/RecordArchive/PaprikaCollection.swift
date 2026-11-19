import Foundation
import zlib

/// Paprika's collection format is a ZIP of gzip-compressed recipe JSON files.
/// Read members in memory. Archive paths never become filesystem destinations.
public enum PaprikaCollection {
    public static let maximumCollectionBytes = 32 * 1_048_576
    private static let memberLimit = ArchiveCodec.maximumNativeBytes
    private static let libraryLimit = ArchiveCodec.maximumFileBytes * 4

    public static func stage(_ data: Data, existing: [ImportedRecipe] = [],
                             existingSourceIDs: Set<String> = []) throws -> RecipeImportReport {
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
        var known = existingSourceIDs.union(existing.map(\.id))
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
            guard known.insert(recipe.id).inserted else { duplicates += 1; continue }
            recipes.append(recipe)
        }
        guard cursor == end else { throw ArchiveError.malformed }
        guard !recipes.isEmpty || duplicates > 0 else { throw ArchiveError.invalidRecipe }
        return RecipeImportReport(recipes: recipes, duplicateCount: duplicates, skippedRows: skipped,
                                  unsupportedFields: unsupported.sorted())
    }

    private static func readRecipe(_ fields: [String: Any], unsupported: inout Set<String>) -> ImportedRecipe? {
        let mapped = ["name", "servings", "ingredients", "directions", "source_url", "source", "notes"]
        for (key, value) in fields where !mapped.contains(key) && !(value is NSNull) {
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
        let recipe = ImportedRecipe(title: title, yieldText: value("servings"), ingredients: lines("ingredients"),
                                    steps: lines("directions"), sourceURL: source.isEmpty ? nil : source, notes: notes)
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
