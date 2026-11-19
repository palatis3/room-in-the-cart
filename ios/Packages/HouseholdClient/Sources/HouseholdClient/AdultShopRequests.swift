import Foundation

public struct AdultShopRequestSession: Equatable, Sendable {
    public let device: HouseholdDeviceSession
    public let shopID: UUID
    let generation: UUID
    let lastCall: Bool
    let reference: Bool
    public let media: Bool
}

public struct ShopLastCall: Decodable, Equatable, Sendable {
    public let managed: Bool
    public let revision: Int
    public let cutoffAt: String?
    public let responded: Bool
    public let muted: Bool
    public let nextShopOnly: Bool
    public var cutoff: Date? { cutoffAt.flatMap(HistoryValidation.date) }
}

public enum LastCallResponse: String, Encodable, Sendable { case pass, mute, unmute }

/// The wire format is a fixed-size RGB raster with no file container or metadata.
public struct ProductReferenceCrop: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: Data

    public init(width: Int, height: Int, pixels: Data) throws {
        guard (8...192).contains(width), (8...192).contains(height), pixels.count == width * height * 3 else {
            throw ClientError.configuration
        }
        self.width = width; self.height = height; self.pixels = pixels
    }

    private enum CodingKeys: String, CodingKey { case width, height, pixels }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: values.decode(Int.self, forKey: .width), height: values.decode(Int.self, forKey: .height),
                      pixels: values.decode(Data.self, forKey: .pixels))
    }
}

public struct AdultProductReference: Codable, Equatable, Sendable {
    public var brand: String?
    public var size: String?
    public var barcode: String?
    public var description: String
    public var crop: ProductReferenceCrop?
    public private(set) var mediaStatus: String?

    public init(brand: String? = nil, size: String? = nil, barcode: String? = nil, description: String,
                crop: ProductReferenceCrop? = nil) throws {
        func optional(_ value: String?) -> String? {
            let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        self.brand = optional(brand); self.size = optional(size); self.barcode = optional(barcode)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.crop = crop
        guard valid else { throw ClientError.configuration }
    }

    var valid: Bool {
        !description.isEmpty && description.utf16.count <= 240 && !description.contains("\0") &&
        [brand, size].allSatisfy { value in value.map { !$0.isEmpty && $0.utf16.count <= 80 && !$0.contains("\0") } ?? true } &&
        (barcode.map { (8...14).contains($0.utf8.count) && $0.utf8.allSatisfy { (48...57).contains($0) } } ?? true)
    }
}

public struct AdultProductReferencePage: Decodable, Equatable, Sendable {
    public let requestRevision: Int
    public let authorityEpoch: Int
    public let recipientId: UUID
    public let recipientLabel: String
    public let revision: Int
    public let reference: AdultProductReference?
    public let expiresAt: String?
    public let own: Bool
}

public enum ProductReferenceReportReason: String, Codable, CaseIterable, Sendable { case unsafe, harassment, other }

extension HouseholdService {
    public func adultShopRequestSession(_ bootstrap: HouseholdBootstrap, shopID: UUID) throws -> AdultShopRequestSession {
        let device = try currentHouseholdDeviceSession()
        guard bootstrap.enrolled, bootstrap.grantId == nil,
              bootstrap.shopId.flatMap(UUID.init(uuidString:)).map({ $0 == shopID }) ?? true, ["organizer","shopper","contributor"].contains(bootstrap.role),
              UUID(uuidString: bootstrap.household.id) == device.householdID,
              UUID(uuidString: bootstrap.memberId) == device.memberID else { throw ClientError.accessEnded }
        return .init(device: device, shopID: shopID, generation: generation, lastCall: bootstrap.capabilities.contains("adult_last_call"),
                     reference: bootstrap.capabilities.contains("adult_product_reference"),
                     media: bootstrap.capabilities.contains("adult_product_reference_media"))
    }

    private func adultRequestPath(_ session: AdultShopRequestSession, requestID: UUID? = nil) throws -> String {
        guard session.generation == generation, try currentHouseholdDeviceSession() == session.device, requestID == nil ? session.lastCall : session.reference else {
            throw ClientError.accessEnded
        }
        let shop = "shops/" + session.shopID.uuidString.lowercased()
        return requestID.map { shop + "/requests/" + $0.uuidString.lowercased() + "/product-reference" } ?? shop + "/last-call"
    }

    public func lastCall(in session: AdultShopRequestSession) async throws -> ShopLastCall {
        let state: ShopLastCall = try await perform(try adultRequestPath(session), method: "GET", reportingShopID: session.shopID.uuidString.lowercased())
        return try validateLastCall(state)
    }

    private func validateLastCall(_ state: ShopLastCall) throws -> ShopLastCall {
        guard state.revision >= 0, state.cutoffAt == nil || state.cutoff != nil else { throw ClientError.invalidResponse }
        return state
    }

    public func publishLastCall(in session: AdultShopRequestSession, reviewed: ShopLastCall,
                                authorityEpoch: Int, cutoffAt: Date) async throws -> ShopLastCall {
        struct Body: Encodable { let expectedRevision: Int; let authorityEpoch: Int; let cutoffAt: String }
        guard reviewed.managed, authorityEpoch > 0 else { throw ClientError.accessEnded }
        let body = Body(expectedRevision: reviewed.revision, authorityEpoch: authorityEpoch,
                        cutoffAt: ISO8601DateFormatter().string(from: cutoffAt))
        return try validateLastCall(await perform(try adultRequestPath(session), method: "POST", body: encoded(body), reportingShopID: session.shopID.uuidString.lowercased()))
    }

    public func respondToLastCall(_ action: LastCallResponse, in session: AdultShopRequestSession,
                                  reviewed: ShopLastCall) async throws -> ShopLastCall {
        struct Body: Encodable { let revision: Int; let action: LastCallResponse }
        guard !reviewed.managed, reviewed.revision > 0 else { throw ClientError.accessEnded }
        return try validateLastCall(await perform(try adultRequestPath(session) + "/response", method: "POST",
                                                   body: encoded(Body(revision: reviewed.revision, action: action)), reportingShopID: session.shopID.uuidString.lowercased()))
    }

    public func productReference(_ request: UUID, in session: AdultShopRequestSession) async throws -> AdultProductReferencePage {
        let page: AdultProductReferencePage = try await perform(try adultRequestPath(session, requestID: request), method: "GET", reportingShopID: session.shopID.uuidString.lowercased(), maximumResponseBytes: 200_000)
        return try checkedReference(page, in: session)
    }

    private func checkedReference(_ page: AdultProductReferencePage, in session: AdultShopRequestSession) throws -> AdultProductReferencePage {
        guard page.revision >= 0, page.authorityEpoch > 0, page.requestRevision > 0, !page.recipientLabel.isEmpty,
              page.own || page.recipientId == session.device.memberID,
              page.reference?.valid != false,
              page.reference == nil || (page.revision > 0 && page.expiresAt.flatMap(HistoryValidation.date).map({ $0 > Date() }) == true),
              page.reference?.crop == nil || (session.media && (page.own || page.reference?.mediaStatus == "approved")) else {
            throw ClientError.invalidResponse
        }
        return page
    }

    public func saveProductReference(_ reference: AdultProductReference, request: UUID, in session: AdultShopRequestSession,
                                     reviewed: AdultProductReferencePage, clientKey: UUID) async throws -> AdultProductReferencePage {
        struct Body: Encodable {
            let expectedRevision: Int; let requestRevision: Int; let authorityEpoch: Int; let recipientId: UUID
            let clientKey: UUID; let consent: Bool; let reference: AdultProductReference
        }
        guard reviewed.own, reference.valid, reference.mediaStatus == nil, reference.crop == nil || session.media else { throw ClientError.configuration }
        let body = Body(expectedRevision: reviewed.revision, requestRevision: reviewed.requestRevision, authorityEpoch: reviewed.authorityEpoch,
                        recipientId: reviewed.recipientId, clientKey: clientKey, consent: true, reference: reference)
        let result: AdultProductReferencePage = try await perform(try adultRequestPath(session, requestID: request), method: "POST",
            body: encoded(body), reportingShopID: session.shopID.uuidString.lowercased(), maximumResponseBytes: 200_000)
        return try checkedReference(result, in: session)
    }

    public func removeProductReference(_ request: UUID, in session: AdultShopRequestSession,
                                       reviewed: AdultProductReferencePage, clientKey: UUID) async throws -> AdultProductReferencePage {
        struct Body: Encodable { let expectedRevision: Int; let clientKey: UUID }
        guard reviewed.own else { throw ClientError.accessEnded }
        let result: AdultProductReferencePage = try await perform(try adultRequestPath(session, requestID: request) + "/remove", method: "POST",
            body: encoded(Body(expectedRevision: reviewed.revision, clientKey: clientKey)), reportingShopID: session.shopID.uuidString.lowercased(), maximumResponseBytes: 200_000)
        return try checkedReference(result, in: session)
    }

    public func moderateProductReference(_ request: UUID, in session: AdultShopRequestSession, reviewed: AdultProductReferencePage,
                                         block: Bool, reason: ProductReferenceReportReason?, clientKey: UUID) async throws {
        struct Body: Encodable { let expectedRevision: Int; let clientKey: UUID; let action: String; let reason: ProductReferenceReportReason? }
        struct Receipt: Decodable { let status: String }
        guard !reviewed.own, reviewed.reference != nil, block == (reason == nil) else { throw ClientError.accessEnded }
        let result: Receipt = try await perform(try adultRequestPath(session, requestID: request) + "/moderation", method: "POST",
            body: encoded(Body(expectedRevision: reviewed.revision, clientKey: clientKey, action: block ? "block" : "report", reason: reason)), reportingShopID: session.shopID.uuidString.lowercased())
        guard result.status == (block ? "blocked" : "received") else { throw ClientError.invalidResponse }
    }
}
