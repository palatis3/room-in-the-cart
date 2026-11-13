#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation

final class SharedFinancialFixture {
    private(set) var closed = false
    private var entries: [[String:Any]] = []
    private var receipts: [String:(Data,Data)] = [:]
    func respond(shop: String, method: String?, path: String, body: [String:Any], revision: inout Int) throws -> (Int, Data) {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func version(_ revision: Int) -> [String:Int] { ["shopRevision": revision, "authorityEpoch": 1, "financialRevision": entries.count] }
        if method == "GET", path.hasSuffix("/financial-evidence") {
            return (200, try json(["shopId":shop,"sourceVersion":version(revision),"evidenceSource":"shopper_reported",
                "entries":entries,"nextCursor":NSNull()] as [String:Any]))
        }
        guard method == "POST", let key = body["clientKey"] as? String else { throw URLError(.badServerResponse) }
        let bytes = try json(body)
        if let saved = receipts[key] {
            guard saved.0 == bytes else { throw URLError(.badServerResponse) }; return (200,saved.1)
        }
        guard body["sourceVersion"] as? [String:Int] == version(revision) else {
            return (409,try json(["error":["code":"stale_source"]]))
        }
        let result: Data
        if path.hasSuffix("/financial-evidence"), let entry = body["entry"] as? [String:Any], let id = entry["id"] as? String {
            entries.append(entry)
            result = try json(["shopId":shop,"entryId":id,"recorded":true,"evidenceSource":"shopper_reported","sourceVersion":version(revision)] as [String:Any])
        } else {
            guard body["allEvidenceEntered"] as? Bool == false, body["closeShop"] as? Bool == true else { throw URLError(.badServerResponse) }
            closed = true; revision += 1
            result = try json(["shopId":shop,"reviewId":UUID().uuidString,"appShopClosed":true,"allEvidenceEntered":false,"sourceVersion":version(revision)] as [String:Any])
        }
        receipts[key] = (bytes,result)
        if receipts.count == 1 { throw URLError(.networkConnectionLost) }
        return (200,result)
    }
}
#endif
