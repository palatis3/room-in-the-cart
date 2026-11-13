import Foundation
import Dispatch

var checks: [String] = []
func check(_ name: String, _ body: () throws -> Void) rethrows {
    try body()
    checks.append(name)
}
func json(_ recorder: ScrollReportWindowRecorder) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try JSONSerialization.jsonObject(with: encoder.encode(recorder.snapshot())) as! [String: Any]
}
try check("empty recorder makes no report claim") {
    let result = try json(ScrollReportWindowRecorder())
    precondition(result["status"] as? String == "no-report-callbacks")
    precondition(result["reportCallbacks"] as? Int == 0)
    precondition((result["events"] as! [Any]).isEmpty)
}
try check("copy IDs and lifecycle order remain explicit") {
    let r = ScrollReportWindowRecorder()
    let a = r.allocateInstance(), b = r.allocateInstance()
    precondition(a != b)
    r.record(kind: "willBegin", instance: b)
    r.record(kind: "didStop", instance: b)
    let t = ScrollWitnessTimestamp(absoluteTime: 1, absoluteTimeNanoSeconds: 2, unixSeconds: 3)
    r.record(kind: "report", instance: b, start: t, end: t)
    let result = try json(r)
    let events = result["events"] as! [[String: Any]]
    precondition(events.map { $0["kind"] as! String } == ["created", "created", "willBegin", "didStop", "report"])
    precondition(events.map { $0["sequence"] as! Int } == Array(1...5))
    precondition(events.last?["instanceOrdinal"] as? String == String(b))
    precondition(result["status"] as? String == "recorded")
}
try check("UInt64 clocks survive JSON without floating point conversion") {
    let r = ScrollReportWindowRecorder()
    let i = r.allocateInstance()
    let t = ScrollWitnessTimestamp(absoluteTime: UInt64.max, absoluteTimeNanoSeconds: UInt64.max-1, unixSeconds: 123.125)
    r.record(kind: "report", instance: i, start: t, end: t)
    let event = (try json(r)["events"] as! [[String: Any]]).last!
    let start = event["suppliedStart"] as! [String: Any]
    precondition(start["absoluteTime"] as? String == "18446744073709551615")
    precondition(start["absoluteTimeNanoSeconds"] as? String == "18446744073709551614")
    precondition(start["unixSeconds"] as? Double == 123.125)
}
try check("nonfinite and reversed timestamps are retained, never normalized") {
    let r = ScrollReportWindowRecorder()
    let i = r.allocateInstance()
    let start = ScrollWitnessTimestamp(absoluteTime: 200, absoluteTimeNanoSeconds: 200, unixSeconds: .infinity)
    let end = ScrollWitnessTimestamp(absoluteTime: 100, absoluteTimeNanoSeconds: 100, unixSeconds: .nan)
    r.record(kind: "report", instance: i, start: start, end: end)
    let event = (try json(r)["events"] as! [[String: Any]]).last!
    let s = event["suppliedStart"] as! [String: Any], e = event["suppliedEnd"] as! [String: Any]
    precondition(s["unixSeconds"] == nil && e["unixSeconds"] == nil)
    precondition(s["invalidUnixSeconds"] as? String == "inf")
    precondition(e["invalidUnixSeconds"] as? String == "nan")
    precondition(s["absoluteTime"] as? String == "200" && e["absoluteTime"] as? String == "100")
}
try check("capacity overflow retains prefix and exact omitted counts") {
    let r = ScrollReportWindowRecorder(capacity: 3)
    let i = r.allocateInstance()
    for _ in 0..<5 { r.record(kind: "report", instance: i) }
    let result = try json(r)
    precondition(result["totalEvents"] as? Int == 6 && result["omittedEvents"] as? Int == 3)
    precondition(result["reportCallbacks"] as? Int == 5)
    precondition(result["status"] as? String == "truncated")
    precondition((result["events"] as! [[String: Any]]).map { $0["sequence"] as! Int } == [1,2,3])
}
try check("zero capacity is explicitly truncated") {
    let r = ScrollReportWindowRecorder(capacity: 0)
    _ = r.allocateInstance()
    let result = try json(r)
    precondition(result["status"] as? String == "truncated")
    precondition(result["omittedEvents"] as? Int == 1)
    precondition((result["events"] as! [Any]).isEmpty)
}
try check("duplicate reports are preserved without inferring iterations") {
    let r = ScrollReportWindowRecorder()
    let i = r.allocateInstance()
    r.record(kind: "report", instance: i)
    r.record(kind: "report", instance: i)
    let result = try json(r)
    precondition(result["reportCallbacks"] as? Int == 2)
    precondition((result["events"] as! [Any]).count == 3)
}
try check("concurrent instance creation and callbacks remain bounded and ordered") {
    let r = ScrollReportWindowRecorder()
    DispatchQueue.concurrentPerform(iterations: 1000) { _ in
        let i = r.allocateInstance()
        r.record(kind: "willBegin", instance: i)
        r.record(kind: "didStop", instance: i)
        r.record(kind: "report", instance: i)
    }
    let result = try json(r)
    let events = result["events"] as! [[String: Any]]
    precondition(result["totalInstances"] as? String == "1000")
    precondition(result["totalEvents"] as? Int == 4000)
    precondition(result["omittedEvents"] as? Int == 3872)
    precondition(result["reportCallbacks"] as? Int == 1000)
    precondition(events.map { $0["sequence"] as! Int } == Array(1...128))
    let created = events.filter { $0["kind"] as? String == "created" }.map { $0["instanceOrdinal"] as! String }
    precondition(Set(created).count == created.count)
}
let report: [String: Any] = ["checksPassed": checks.count, "checks": checks,
    "scope": "Foundation-only recorder validation; no XCTest callback/runtime compatibility claim"]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
