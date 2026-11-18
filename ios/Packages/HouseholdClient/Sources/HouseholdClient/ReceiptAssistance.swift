import Foundation

public struct ReceiptAssistanceScope: Equatable, Sendable {
    public let subject: String
    public let householdID: String
    public let memberID: String
    public let shopID: String?
    public init(subject: String, householdID: String, memberID: String, shopID: String?) {
        self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.shopID = shopID
    }
}

public struct ReceiptLineCrop: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) throws {
        guard (8...768).contains(width), (8...240).contains(height), pixels.count == width * height else {
            throw ClientError.invalidResponse
        }
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public struct ReceiptLineAssistanceRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let issuedAt: Int64
    public let consent: Bool
    public let page: Int
    public let line: Int
    public let text: String
    public let crop: ReceiptLineCrop?

    public static func accepts(_ text: String, crop: ReceiptLineCrop? = nil) -> Bool {
        let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!selected.isEmpty || crop != nil) && selected.utf8.count <= 512 && selected.count <= 500 &&
            selected.rangeOfCharacter(from: .controlCharacters) == nil
    }

    public func wireData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(consentingTo text: String, page: Int, line: Int, crop: ReceiptLineCrop? = nil, now: Date = Date()) throws {
        let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.accepts(selected, crop: crop), (1...20).contains(page), (1...200).contains(line) else { throw ClientError.invalidResponse }
        self.version = 1
        self.requestID = UUID()
        self.issuedAt = Int64(now.timeIntervalSince1970 * 1_000)
        self.consent = true
        self.page = page; self.line = line; self.text = selected; self.crop = crop
    }
}

public struct ReceiptLineSuggestion: Decodable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let page: Int
    public let line: Int
    public let foodName: String?
    public let quantity: String?
    public let unit: String?

    public func validate(for request: ReceiptLineAssistanceRequest) throws {
        guard version == 1, requestID == request.requestID, page == request.page, line == request.line,
              (quantity == nil) == (unit == nil) else { throw ClientError.invalidResponse }
        if let foodName {
            guard !foodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, foodName.count <= 100,
                  foodName.utf8.count <= 512, foodName.rangeOfCharacter(from: .controlCharacters) == nil else { throw ClientError.invalidResponse }
        }
        if let quantity, let unit {
            guard quantity.range(of: #"^(?:0|[1-9][0-9]{0,4})(?:\.[0-9]{1,3})?$"#, options: .regularExpression) != nil,
                  Double(quantity).map({ $0 > 0 }) == true,
                  ["count","gram","kilogram","ounce","pound","milliliter","liter","fluidOunce","cup"].contains(unit) else {
                throw ClientError.invalidResponse
            }
        }
    }
}

public enum ImageAssistancePurpose: String, Sendable { case recipe, shelf, checkout }

public struct ImageWordingSuggestion: Decodable, Equatable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let page: Int
    public let line: Int
    public let wording: String?

    public func validate(for request: ReceiptLineAssistanceRequest) throws {
        guard version == 1, requestID == request.requestID, request.crop != nil,
              page == request.page, line == request.line,
              wording.map({ ReceiptLineAssistanceRequest.accepts($0) }) ?? true else { throw ClientError.invalidResponse }
    }
}

public struct ReceiptAssistanceAvailability: Decodable, Sendable {
    public let version: Int
    public let available: Bool
    public let allowsCrop: Bool?
}

extension HouseholdService {
    public func receiptAssistanceAvailability(scope: ReceiptAssistanceScope) async throws -> ReceiptAssistanceAvailability {
        try verifyReceiptAssistanceScope(scope)
        let result: ReceiptAssistanceAvailability = try await perform("receipt-assistance", method: "GET", reportingShopID: scope.shopID, maximumResponseBytes: 1024)
        guard result.version == 1 else { throw ClientError.invalidResponse }
        return result
    }

    public func visibleImageLine(_ input: ReceiptLineAssistanceRequest, purpose: ImageAssistancePurpose,
                                 scope: ReceiptAssistanceScope) async throws -> ImageWordingSuggestion {
        try verifyReceiptAssistanceScope(scope)
        guard input.crop != nil else { throw ClientError.invalidResponse }
        let result: ImageWordingSuggestion = try await perform("capture-assistance/" + purpose.rawValue + "-line",
            method: "POST", body: input.wireData(), reportingShopID: scope.shopID, maximumResponseBytes: 2048)
        try result.validate(for: input)
        return result
    }

    public func receiptLineSuggestion(_ input: ReceiptLineAssistanceRequest, scope: ReceiptAssistanceScope) async throws -> ReceiptLineSuggestion {
        try verifyReceiptAssistanceScope(scope)
        let result: ReceiptLineSuggestion = try await perform("receipt-assistance", method: "POST", body: input.wireData(),
            reportingShopID: scope.shopID, maximumResponseBytes: 2048)
        try result.validate(for: input)
        return result
    }
}
