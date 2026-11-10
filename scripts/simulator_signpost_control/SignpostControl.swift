import Foundation
import os
import Darwin

#if !targetEnvironment(simulator)
#error("This diagnostic helper must target the iOS Simulator")
#endif

// Scratch control only: no app target, UIKit, XCTest, or production source changes.
guard CommandLine.arguments.count == 5 else { exit(64) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let nonce = CommandLine.arguments[2]
let expectedUDID = CommandLine.arguments[3]
let subsystem = CommandLine.arguments[4]
guard nonce.count == 32, subsystem.hasPrefix("dev.roominthecart.collectorcontrol."),
      subsystem.utf8.count < 128 else { exit(64) }
let environment = ProcessInfo.processInfo.environment
let actualUDID = environment["SIMULATOR_UDID"] ?? ""
let started = ProcessInfo.processInfo.systemUptime
let lifetime: TimeInterval = 60

func status(_ stage: String) {
    let value: [String: Any] = [
        "stage": stage, "nonce": nonce, "pid": getpid(), "parentPID": getppid(),
        "uid": getuid(), "simulatorUDID": actualUDID,
        "simulatorRoot": environment["SIMULATOR_ROOT"] ?? "",
        "compiledForSimulator": true, "subsystem": subsystem
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("helper-status.json"), options: .atomic)
    } catch { exit(74) }
}

func command(_ expected: String) -> Bool {
    while ProcessInfo.processInfo.systemUptime - started < lifetime {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("helper-command.txt")),
           String(data: data, encoding: .utf8) == expected + " " + nonce + "\n" { return true }
        usleep(50_000)
    }
    status("deadline")
    return false
}

guard actualUDID.caseInsensitiveCompare(expectedUDID) == .orderedSame else {
    status("simulator_identity_rejected")
    // Allow the supervisor to bind and terminate this exact process even on rejection.
    _ = command("Q")
    exit(65)
}
let signposter = OSSignposter(subsystem: subsystem, category: "OwnedControl")
status("waiting")
guard command("G") else { exit(75) }
signposter.emitEvent("ControlBefore")
let names: [StaticString] = ["ControlInterval1", "ControlInterval2", "ControlInterval3"]
for name in names {
    let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
    usleep(50_000)
    signposter.endInterval(name, state)
}
signposter.emitEvent("ControlAfter")
status("emitted")
guard command("Q") else { exit(75) }
status("finished")
exit(0)
