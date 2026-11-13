#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import Foundation

/// Persistent synthetic remote evidence for ordinary native confirmation/retry controls.
/// Authorization and mutation semantics are independently tested against real PostgreSQL.
final class SharedConfirmedOrderUIFixture {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UITestWorkspace/ConfirmedOrder", isDirectory: true)
    private let file = SharedConfirmedOrderUIFixture.folder.appendingPathComponent("remote.json")
    private var state: [String:Any]
    var revision: Int { 2 + (state["amendments"] as? [[String:Any]] ?? []).count }
    init() {
        if ProcessInfo.processInfo.arguments.contains("--reset-confirmed-order-fixture") { try? FileManager.default.removeItem(at: Self.folder) }
        if let bytes=try? Data(contentsOf:file), let saved=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] { state=saved }
        else {
            let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            let created=formatter.string(from:Date().addingTimeInterval(-60))
            let quote:[String:Any]=["currency":"USD","scope":"wholeCheckout","complete":true,"capMinor":1000,"capScope":"wholeCheckout",
                "fee":["kind":"fixed","amountMinor":0],"taxesMinor":0,"depositsMinor":0,"discountsMinor":0,
                "observedAt":created,"expiresAt":formatter.string(from:Date().addingTimeInterval(3600))]
            let line:[String:Any]=["lineId":"66666666-6666-4666-8666-666666666666","originalItem":"Entered soup packs","packs":1,"unitPriceMinor":500,"feeEligible":true]
            state=["original":["lines":[line],"quote":quote,"snapshotCreatedAt":created],"current":["lines":[line],"amendmentId":NSNull()],"amendments":[],"receipts":[:],"commands":[:],"dropped":false]
            try? persist()
        }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at:Self.folder,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]).write(to:file,options:.atomic)
    }
    func page(shop:String) -> [String:Any] {
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return ["shopId":shop,"shopRevision":revision,"authorityEpoch":1,"placedRevision":1,"asOf":formatter.string(from:Date()),
                "original":state["original"]!,"current":state["current"]!,"amendments":state["amendments"]!]
    }
    func record(shop:String,actor:String,input:[String:Any],bytes:Data) throws -> [String:Any] {
        guard let key=input["clientKey"] as? String,let body=input["body"] as? [String:Any] else { throw SharedDeliveryFixtureRecords.CookFailure.invalid }
        var receipts=state["receipts"] as? [String:[String:Any]] ?? [:], commands=state["commands"] as? [String:String] ?? [:]
        if let receipt=receipts[key] {
            guard commands[key]==bytes.base64EncodedString() else { throw SharedDeliveryFixtureRecords.CookFailure.replayConflict }
            return receipt
        }
        guard (input["base"] as? [String:Any])?["shopRevision"] as? Int == revision,
              let lines=body["lines"] as? [[String:Any]],let reference=body["retailerReference"] as? String,
              let confirmed=body["confirmedAt"] as? String else { throw SharedDeliveryFixtureRecords.CookFailure.staleBase }
        let id=UUID().uuidString.lowercased(), formatter=ISO8601DateFormatter()
        formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        var history=state["amendments"] as? [[String:Any]] ?? []
        history.append(["amendmentId":id,"predecessorId":body["predecessorId"] ?? NSNull(),"retailerReference":reference,
                        "confirmedAt":confirmed,"recordedAt":formatter.string(from:Date()),"actorId":actor,"actorLabel":"Fixture shopper","lines":lines])
        state["amendments"]=history;state["current"]=["lines":lines,"amendmentId":id]
        let receipt:[String:Any]=["operationId":id,"amendmentId":id,"kind":"amendment.recordResponse","shopId":shop,
                                  "shopRevision":revision,"authorityEpoch":1,"placedRevision":1,"disposition":"recorded"]
        receipts[key]=receipt;commands[key]=bytes.base64EncodedString();state["receipts"]=receipts;state["commands"]=commands
        let drop=ProcessInfo.processInfo.arguments.contains("--confirmed-order-drop-reply") && state["dropped"] as? Bool != true
        if drop { state["dropped"]=true }
        try persist()
        if drop { throw URLError(.notConnectedToInternet) }
        return receipt
    }
}
#endif
