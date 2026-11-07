import XCTest

/// Standalone witness. Never wraps or delegates to a built-in metric.
final class ScrollReportWindowWitness: NSObject, XCTMetric {
    private let recorder: ScrollReportWindowRecorder
    private let instance: UInt64

    init(recorder: ScrollReportWindowRecorder) {
        self.recorder = recorder
        self.instance = recorder.allocateInstance()
        super.init()
    }

    func copy(with zone: NSZone? = nil) -> Any {
        ScrollReportWindowWitness(recorder: recorder)
    }

    func willBeginMeasuring() { recorder.record(kind: "willBegin", instance: instance) }
    func didStopMeasuring() { recorder.record(kind: "didStop", instance: instance) }

    func reportMeasurements(from startTime: XCTPerformanceMeasurementTimestamp,
                            to endTime: XCTPerformanceMeasurementTimestamp) throws -> [XCTPerformanceMeasurement] {
        let start = ScrollWitnessTimestamp(absoluteTime: startTime.absoluteTime,
            absoluteTimeNanoSeconds: startTime.absoluteTimeNanoSeconds,
            unixSeconds: startTime.date.timeIntervalSince1970)
        let end = ScrollWitnessTimestamp(absoluteTime: endTime.absoluteTime,
            absoluteTimeNanoSeconds: endTime.absoluteTimeNanoSeconds,
            unixSeconds: endTime.date.timeIntervalSince1970)
        recorder.record(kind: "report", instance: instance, start: start, end: end)
        return [] // No invented metric, sample, or duration.
    }
}
