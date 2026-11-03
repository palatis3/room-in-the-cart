import Foundation

/// A material field still requiring review. Unresolved negation is not a positive request.
public enum CaptureImportField: String, Codable, CaseIterable, Hashable, Sendable {
    case name, quantity, packCount, amountPerPack, purpose, destination, exclusions, negation
}

public enum CaptureImportError: Error, Equatable, Sendable {
    case invalidField(CaptureImportField)
    case conflictingQuantity
    case reviewRequired([CaptureImportField])
    case unsupportedVersion(Int)
}

/// Reviewed capture evidence, independent of later line edits. Purpose and destination
/// are labels: they grant no authority, redirect no command, and create no meal/reservation.
public struct CaptureImportMetadata: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public var declaredQuantity: Quantity?
    public var packCount: Int?
    public var amountPerPack: Quantity?
    public var purpose: String
    public var destination: String
    public var unresolvedFields: [CaptureImportField]

    public init(declaredQuantity: Quantity? = nil, packCount: Int? = nil, amountPerPack: Quantity? = nil,
                purpose: String = "", destination: String = "", unresolvedFields: [CaptureImportField] = []) {
        formatVersion = 1; self.declaredQuantity = declaredQuantity; self.packCount = packCount
        self.amountPerPack = amountPerPack; self.purpose = purpose; self.destination = destination
        self.unresolvedFields = unresolvedFields
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw CaptureImportError.unsupportedVersion(formatVersion) }
        try declaredQuantity?.validate(); try amountPerPack?.validate()
        if let packCount, packCount < 0 || Int64(exactly: packCount) == nil {
            throw CaptureImportError.invalidField(.packCount)
        }
        try captureText(purpose, field: .purpose, maximum: 512)
        try captureText(destination, field: .destination, maximum: 512)
        guard Set(unresolvedFields).count == unresolvedFields.count else { throw LedgerError.invalid("captureReviewFields") }
    }

    /// Exact food quantity. A pack is never implicitly a food unit; uncertain amounts
    /// remain nil. A supplied total must agree with complete, confirmed pack evidence.
    public func resolvedQuantity() throws -> Quantity? {
        try validate()
        let uncertain: Set<CaptureImportField> = [.name, .quantity, .packCount, .amountPerPack, .exclusions, .negation]
        if !uncertain.isDisjoint(with: unresolvedFields) { return nil }
        let packed: Quantity?
        if let packCount, let amountPerPack {
            let amount = try amountPerPack.amount.multiplied(by: Rational(Int64(packCount)))
            packed = Quantity(amount: amount, unit: amountPerPack.unit,
                originalLiteral: "\(packCount) × \(amountPerPack.amount) \(amountPerPack.unit.rawValue)",
                confirmedConversion: amountPerPack.confirmedConversion)
        } else if packCount != nil || amountPerPack != nil { return nil }
        else { packed = nil }
        if let declaredQuantity, let packed {
            guard let converted = try packed.converted(to: declaredQuantity.unit), converted == declaredQuantity.amount
            else { throw CaptureImportError.conflictingQuantity }
            return declaredQuantity
        }
        return declaredQuantity ?? packed
    }

    public var blockingFields: [CaptureImportField] {
        CaptureImportField.allCases.filter { [.name, .exclusions, .negation].contains($0) && unresolvedFields.contains($0) }
    }

    var normalized: CaptureImportMetadata {
        var next = self, fields = Set(unresolvedFields)
        if packCount != nil && amountPerPack == nil { fields.insert(.amountPerPack) }
        if amountPerPack != nil && packCount == nil { fields.insert(.packCount) }
        if declaredQuantity == nil && packCount == nil && amountPerPack == nil { fields.insert(.quantity) }
        next.unresolvedFields = CaptureImportField.allCases.filter { fields.contains($0) }
        return next
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, declaredQuantity, packCount, amountPerPack, purpose, destination, unresolvedFields
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        declaredQuantity = try c.decodeIfPresent(Quantity.self, forKey: .declaredQuantity)
        packCount = try c.decodeIfPresent(Int.self, forKey: .packCount)
        amountPerPack = try c.decodeIfPresent(Quantity.self, forKey: .amountPerPack)
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose) ?? ""
        destination = try c.decodeIfPresent(String.self, forKey: .destination) ?? ""
        unresolvedFields = try c.decodeIfPresent([CaptureImportField].self, forKey: .unresolvedFields) ?? []
        try validate()
    }
}

/// Reserve IDs before review and preserve the complete preview for retries. Corrections
/// change the reviewed name, never the original wording. Quantity means a total amount.
public struct CaptureImportLine: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let proposedLineID: UUID
    public let originalText: String
    public var name: String
    public var quantity: Quantity?
    public var packCount: Int?
    public var amountPerPack: Quantity?
    public var purpose: String
    public var destination: String
    public var exclusions: [String]
    public var unresolvedFields: [CaptureImportField]

    public init(id: UUID = UUID(), proposedLineID: UUID = UUID(), originalText: String, name: String,
                quantity: Quantity? = nil, packCount: Int? = nil, amountPerPack: Quantity? = nil,
                purpose: String = "", destination: String = "", exclusions: [String] = [],
                unresolvedFields: [CaptureImportField] = []) {
        self.id = id; self.proposedLineID = proposedLineID; self.originalText = originalText; self.name = name
        self.quantity = quantity; self.packCount = packCount; self.amountPerPack = amountPerPack
        self.purpose = purpose; self.destination = destination; self.exclusions = exclusions
        self.unresolvedFields = unresolvedFields
    }

    public func validate() throws {
        try captureText(originalText, field: .name, maximum: 8_192)
        try captureText(name, field: .name, maximum: 512, nonempty: true)
        guard exclusions.count <= 100 else { throw CaptureImportError.invalidField(.exclusions) }
        for exclusion in exclusions { try captureText(exclusion, field: .exclusions, maximum: 512, nonempty: true) }
        try metadata.validate()
    }

    var metadata: CaptureImportMetadata {
        CaptureImportMetadata(declaredQuantity: quantity, packCount: packCount, amountPerPack: amountPerPack,
            purpose: purpose, destination: destination, unresolvedFields: unresolvedFields).normalized
    }
}

extension ShoppingLedger {
    /// Stages evidence without text reparsing or business mutation. Apply this preview once
    /// with commitImport. Caller checks shopper authority independently; a contributor
    /// confirms their own request, never this basket command. Guest changes use the dinner
    /// proposal engine, not purpose/destination labels from capture.
    public func stageCaptureImport(id importID: UUID, originalText: String, source: ImportSource,
                                   lines captured: [CaptureImportLine]) throws -> StagedListImport {
        guard originalText.utf8.count <= 262_144, !originalText.contains("\0"), captured.count <= 1_000,
              Set(captured.map(\.id)).count == captured.count,
              Set(captured.map(\.proposedLineID)).count == captured.count
        else { throw LedgerError.invalid("captureImport") }
        var rows: [StagedImportLine] = []
        for line in captured {
            try line.validate()
            let metadata = line.metadata
            rows.append(StagedImportLine(id: line.id, proposedLineID: line.proposedLineID,
                originalText: line.originalText, name: line.name, quantity: try metadata.resolvedQuantity(),
                unresolvedReason: metadata.unresolvedFields.isEmpty ? nil : "Review the unresolved capture fields.",
                duplicateLineIDs: [], exclusions: line.exclusions, capture: metadata))
        }
        return try refreshImportMatches(StagedListImport(id: importID, shopID: self.id, baseRevision: revision,
            source: source, originalText: originalText, lines: rows))
    }
}

private func captureText(_ value: String, field: CaptureImportField, maximum: Int, nonempty: Bool = false) throws {
    guard value.utf8.count <= maximum, !value.contains("\0"),
          !nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw CaptureImportError.invalidField(field) }
}
