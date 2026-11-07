# Local speech priority-inversion reproducer

This iPhone simulator control initializes an AVSpeechSynthesizer and offers the four public speech actions. It has no application audio-session setup, private cook text, household data, service calls or custom queues. One UI test opens the screen and leaves it idle. The other uses the four actions in sequence.

Use a separate evidence directory and an iPhone simulator. The existing standalone Xcode project supplies the app and UI test targets.

```sh
mkdir -p "$EVIDENCE/control"
cp -R diagnostics/swiftui-toggle/FormToggleDiagnostic.xcodeproj "$EVIDENCE/control/"
cp diagnostics/cook-speech-qos/SpeechControl.swift "$EVIDENCE/control/FormToggleDiagnostic.swift"
cp diagnostics/cook-speech-qos/SpeechControlUITests.swift "$EVIDENCE/control/FormToggleDiagnosticUITests.swift"
sed -i '' 's/org.roominthecart.diagnostics.formtoggle/org.roominthecart.diagnostics.speechqos/g' \
  "$EVIDENCE/control/FormToggleDiagnostic.xcodeproj/project.pbxproj"

xcodebuild -project "$EVIDENCE/control/FormToggleDiagnostic.xcodeproj" -scheme FormToggleDiagnostic \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$EVIDENCE/build" -resultBundlePath "$EVIDENCE/control.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGN_IDENTITY=- test
```

To inspect the runtime checker independently of the test summary, record the start time and query the simulator log for the control's process immediately after the test.

```sh
xcrun simctl spawn "$SIMULATOR_ID" log show --start "$START_TIME" --style json \
  --predicate 'process == "FormToggleDiagnostic" AND subsystem == "com.apple.runtime-issues" AND category == "Hang Risk"'
```

## Observed on iOS 26.2

On iPhone 17, iOS 26.2 build 23C54, Xcode 27.1, both standalone tests passed. The idle launch recorded zero XCTest warnings. The public speech case emitted a priority-inversion warning during the Speak tap. Running the shipping readback UI followed by the saved-copy UI produced the warning during Play. Running saved copy alone passed the strict checker with zero warnings.

The simulator runtime checker recorded six Hang Risk events in the product and six in this control. Every product event matched a control event on the first six image UUIDs and offsets. Each began with three Foundation frames followed by three TextToSpeech frames. The runtime reported the waiting operation as `-[NSCondition wait]`. One product stack included the call into `AVSpeechSynthesizer.pauseSpeaking` from `LocalCookSpeech.pause`. The other five contained only application entry points among their app-specific frames. A separate run of a standalone implementation calling the public speech API on a default-QoS serial queue also reproduced all five distinct six-frame signatures.

The local product and standalone XCTest summaries each aggregated these events into one warning and omitted the required complete-issue attachment. The repository's strict checker failed for both. Its runtime-warning policy remains unchanged.

In hosted run 42402979723 job 128513144719, Xcode 26.3 recorded the same warning text during termination of the old app in the next saved-copy case. Its 23 source frames contain no symbols or usable addresses. The local speech stack identifies the cause on the simulator used here. The hosted termination warning's originating stack remains unknown.
