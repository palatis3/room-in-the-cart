import json
import io
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import zlib

import preservation
import protocol
import run


def journal(pid=42, events=None):
    events = events or [(1, "observer.installed"), (9, "comparison.focus.bQuantity"),
                        (10.1, "done.enter"), (10.2, "done.exit"),
                        (10.3, "comparison.focus.none"), (10.4, "keyboard.didHide"),
                        (12, "textField.beginEditing")]
    return "".join(f"SDD1|{pid}|{i}|{time}|{event}|"
                   + ("comparison" if event.startswith(("comparison.", "done.", "focus.")) else "process") + "\n"
                   for i, (time, event) in enumerate(events, 1))


MARKERS = "SDD_RUNNER|before|31|10\nSDD_RUNNER|after|31|11\n"


def png(payload=b"\0\0\0\0", width=1, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(payload)) + chunk(b"IEND", b""))


class JournalProtocolTests(unittest.TestCase):
    def test_independent_sink_agreement_never_becomes_a_causal_verdict(self):
        raw = journal()
        live = "capture startup\n" + "".join("host pid info: " + line + "\n" for line in raw.splitlines())
        result = protocol.compare_sinks({"process-42.events": raw}, live, live, MARKERS)
        self.assertEqual(result["events"], 7)
        self.assertFalse(result["absenceInferenceAllowed"])
        self.assertIsNone(result["causalConclusion"])

    def test_previous_empty_persisted_capture_is_rejected_even_with_live_events(self):
        with self.assertRaisesRegex(ValueError, "disagree"):
            protocol.compare_sinks({"process-42.events": journal()}, journal(), "", MARKERS)

    def test_unknown_tokens_partial_lines_gaps_duplicates_and_sink_errors_are_rejected(self):
        bad = [journal().rstrip(), journal().replace("done.enter", "user.food.text"),
               journal().replace("|3|", "|4|"), journal() + journal(), "SDD_ERROR|42|write\n",
               journal().replace("|12|", "|0.1|"), journal().replace("|1|observer", "|" + "9" * 400 + "|observer")]
        for raw in bad:
            with self.subTest(raw=raw[:70]), self.assertRaises(ValueError):
                protocol.parse_events(raw, journal=True)

    def test_process_name_activation_and_post_marker_coverage_are_required(self):
        cases = [({"process-43.events": journal()}, MARKERS),
                 ({"process-42.events": journal().replace("observer.installed", "done.enter")}, MARKERS),
                 ({"process-42.events": journal()}, MARKERS.replace("after|31|11", "after|31|15")),
                 ({}, MARKERS)]
        for journals, markers in cases:
            with self.subTest(journals=list(journals)), self.assertRaises(ValueError):
                protocol.compare_sinks(journals, journal(), journal(), markers)

    def test_journal_byte_and_event_caps(self):
        with self.assertRaises(ValueError):
            protocol.parse_events("x" * (protocol.MAX_JOURNAL_BYTES + 1), journal=True)
        raw = journal(events=[(i, "observer.installed" if i == 0 else "keyboard.didHide")
                              for i in range(protocol.MAX_EVENTS + 1)])
        with self.assertRaises(ValueError):
            protocol.parse_events(raw, journal=True)

    def test_missing_or_duplicate_runner_markers_are_incomplete(self):
        for text in ("", MARKERS.splitlines()[0], MARKERS + MARKERS,
                     MARKERS.replace("after|31", "after|99")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                protocol.parse_markers(text)

    def test_missing_done_entry_is_not_misreported_as_a_known_cause(self):
        raw = journal(events=[(1, "observer.installed"), (9, "comparison.focus.bQuantity"),
                              (12, "textField.beginEditing")])
        result = protocol.compare_sinks({"process-42.events": raw}, raw, raw, MARKERS)
        self.assertFalse(result["absenceInferenceAllowed"])
        self.assertIsNone(result["causalConclusion"])


    def test_other_process_cannot_supply_post_done_coverage(self):
        first = journal(events=[(1, "observer.installed"), (9, "comparison.focus.bQuantity")])
        second = journal(pid=43, events=[(12, "observer.installed")])
        with self.assertRaisesRegex(ValueError, "target app process"):
            protocol.compare_sinks({"process-42.events": first, "process-43.events": second},
                                  first + second, first + second, MARKERS)

    def test_ambiguous_or_only_later_target_focus_is_incomplete(self):
        for first, second in ((journal(), journal(pid=43)),
                              (journal(events=[(1, "observer.installed"),
                                               (12, "comparison.focus.bQuantity")]), "")):
            journals = {"process-42.events": first}
            if second:
                journals["process-43.events"] = second
            with self.subTest(second=bool(second)), self.assertRaisesRegex(ValueError, "one app process"):
                protocol.compare_sinks(journals, first + second, first + second, MARKERS)

    def test_relaunch_can_coexist_with_target_process_coverage(self):
        first, second = journal(), journal(pid=43, events=[(13, "observer.installed")])
        result = protocol.compare_sinks({"process-42.events": first, "process-43.events": second},
                                       first + second, first + second, MARKERS)
        self.assertEqual(result["targetProcessID"], 42)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def test_valid_still_is_fully_decompressed(self):
        path = self.root / "still.png"
        path.write_bytes(png())
        self.assertEqual(protocol.validate_png(path), {"width": 1, "height": 1, "decodedBytes": 4})

    def test_pending_recording_text_corruption_and_zip_bomb_style_png_are_rejected(self):
        for data in (b"Unexpected Error: Finished test run with pending attachment.", png()[:-5],
                     png() + b"trailing", png(payload=b"\0" * 100000), png(width=4097), png(payload=b"\5\0\0\0")):
            path = self.root / "still.png"
            path.write_bytes(data)
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                protocol.validate_png(path)

    def test_collector_only_copies_fixed_bounded_regular_journals(self):
        source = self.root / "source"
        source.mkdir()
        (source / "process-42.events").write_text(journal())
        self.assertEqual(run.collect_journals(source, self.root / "copied"), {"process-42.events": journal()})
        (source / "unrelated.txt").write_text("must not collect")
        with self.assertRaises(ValueError):
            run.collect_journals(source, self.root / "rejected")

    def test_linked_or_oversized_journal_is_rejected(self):
        source = self.root / "source"
        source.mkdir()
        target = self.root / "target"
        target.write_text(journal())
        (source / "process-42.events").symlink_to(target)
        with self.assertRaises(ValueError):
            run.collect_journals(source, self.root / "links")
        (source / "process-42.events").unlink()
        (source / "process-42.events").write_bytes(b"x" * (protocol.MAX_JOURNAL_BYTES + 1))
        with self.assertRaises(ValueError):
            run.collect_journals(source, self.root / "oversize")

    def test_test_failure_is_retained_even_when_frozen_input_check_fails(self):
        run.write(self.root / "test-status.json", {"invoked": True, "exit": 65})
        with patch("run.command", side_effect=ValueError("result not readable")), \
             patch("run.frozen", side_effect=ValueError("changed input")):
            self.assertEqual(run.collect(self.root), 1)
        self.assertEqual(json.loads((self.root / "test-result.json").read_text())["raw"]["exit"], 65)
        self.assertFalse(json.loads((self.root / "capture-status.json").read_text())["complete"])

    def test_stopping_owned_capture_records_graceful_and_forced_outcomes(self):
        child = Mock(pid=123, returncode=0)
        child.poll.return_value = None
        result = run.stop_capture(child, video=True)
        child.send_signal.assert_called_once_with(signal.SIGINT)
        self.assertFalse(result["forced"])
        child = Mock(pid=456, returncode=-9)
        child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired("fake", 20), -9]
        result = run.stop_capture(child, video=True)
        child.kill.assert_called_once()
        self.assertTrue(result["forced"])

    def test_external_stills_are_exactly_two_bounded_read_only_commands(self):
        stop, result = Mock(), []
        stop.wait.return_value = False
        with patch("run.subprocess.run", return_value=subprocess.CompletedProcess([], 0)) as invoke:
            run.capture_stills("owned-device", self.root, stop, 0, result)
        self.assertEqual(len(result), 2)
        self.assertEqual([r["requestedDelaySeconds"] for r in result], [5, 15])
        self.assertEqual(invoke.call_count, 2)
        for call in invoke.call_args_list:
            self.assertEqual(call.args[0][:5], ["xcrun", "simctl", "io", "owned-device", "screenshot"])
            self.assertEqual(call.kwargs["timeout"], 15)

    def test_still_timeout_is_capture_failure_without_touching_test_status(self):
        stop, result = Mock(), []
        stop.wait.return_value = False
        with patch("run.subprocess.run", side_effect=subprocess.TimeoutExpired("fake", 15)):
            run.capture_stills("owned-device", self.root, stop, 0, result)
        self.assertTrue(all("error" in item and "exit" not in item for item in result))

    def test_complete_capture_does_not_turn_an_original_test_failure_into_success(self):
        container = self.root / "container"
        directory = container / "Library/Caches/SpanishDoneDiagnostic"
        directory.mkdir(parents=True)
        (directory / "process-42.events").write_text(journal())
        (self.root / "Tests.log").write_text(MARKERS)
        (self.root / "events-live.log").write_text(journal())
        (self.root / "screen.mp4").write_bytes(b"unverified-video" * 100)
        for delay in (5, 15):
            (self.root / f"after-bQuantity-Done-{delay}s.png").write_bytes(png())
        run.write(self.root / "capture-stop.json", {
            "live": {"aliveBeforeStop": True, "forced": False, "exit": -15},
            "video": {"aliveBeforeStop": True, "forced": False, "exit": 0}})
        run.write(self.root / "stills-status.json", [{"exit": 0}, {"exit": 0}])
        original = {"raw": {"exit": 65}, "strictExit": 1}

        def export(_args, **kwargs):
            kwargs["stdout"].write(journal())
            return subprocess.CompletedProcess([], 0)

        with patch("run.collect_test_result", return_value=original), patch("run.frozen"), \
             patch("run.owned", return_value=("owned-device", {})), \
             patch("run.command", return_value=str(container)), patch("run.subprocess.run", side_effect=export):
            self.assertEqual(run.collect(self.root), 1)
        capture = json.loads((self.root / "capture-status.json").read_text())
        self.assertTrue(capture["complete"])
        self.assertFalse(capture["records"]["videoDecoded"])
        self.assertFalse(capture["absenceInferenceAllowed"])
        self.assertEqual(original["raw"]["exit"], 65)
        # Repeat collection against an unchanged complete capture, preserving raw
        # zero exit while signal/interruption/harness failure remains a failure.
        for failure in ({"signal": 15}, {"interrupted": True}, {"harnessError": "cancelled"}):
            original = {"raw": {"invoked": True, "exit": 0, **failure}, "strictExit": 0}
            shutil.rmtree(self.root / "journals")
            with self.subTest(failure=failure), patch("run.collect_test_result", return_value=original), \
                 patch("run.frozen"), patch("run.owned", return_value=("owned-device", {})), \
                 patch("run.command", return_value=str(container)), patch("run.subprocess.run", side_effect=export):
                self.assertEqual(run.collect(self.root), 1)
            self.assertEqual(original["raw"]["exit"], 0)

    def test_execute_uses_one_original_selector_and_unchanged_deadlines_without_retry(self):
        products = self.root / "products"
        products.mkdir()
        (products / "RoomInTheCart_iphonesimulator26.2.xctestrun").touch()
        (self.root / "selectors.txt").write_text(run.SELECTOR + "\n")
        container = self.root / "container"
        container.mkdir()
        live, video = Mock(pid=10, returncode=-15), Mock(pid=11, returncode=0)
        live.poll.return_value = video.poll.return_value = None
        test = Mock(pid=12, returncode=65, stdout=io.StringIO(MARKERS))
        test.poll.return_value = test.wait.return_value = 65
        with patch("run.frozen"), patch("run.verify_runtime", return_value=("owned-device", {})), \
             patch("run.command", return_value=str(container)), patch("run.time.sleep"), \
             patch("run.threading.Thread"), patch("run.subprocess.Popen", side_effect=[live, video, test]) as start:
            self.assertEqual(run.execute(self.root, products), 1)
        args = json.loads((self.root / "test-command.json").read_text())
        self.assertEqual([x for x in args if x.startswith("-only-testing:")], ["-only-testing:" + run.SELECTOR])
        self.assertEqual(args[args.index("-default-test-execution-time-allowance") + 1], "720")
        self.assertEqual(args[args.index("-maximum-test-execution-time-allowance") + 1], "900")
        self.assertEqual(start.call_count, 3)  # live log + video + one xcodebuild
        self.assertEqual(json.loads((self.root / "test-status.json").read_text())["exit"], 65)
        with self.assertRaisesRegex(ValueError, "no reuse/retry"):
            run.execute(self.root, products)


    def test_cancellation_after_zero_test_exit_is_retained_and_fails(self):
        products = self.root / "products"
        products.mkdir()
        (products / "RoomInTheCart_iphonesimulator26.2.xctestrun").touch()
        (self.root / "selectors.txt").write_text(run.SELECTOR + "\n")
        container = self.root / "container"
        container.mkdir()
        live, video = Mock(pid=10, returncode=-15), Mock(pid=11, returncode=0)
        live.poll.return_value = video.poll.return_value = None
        test = Mock(pid=12, returncode=0, stdout=io.StringIO(MARKERS))
        test.poll.return_value = test.wait.return_value = 0
        handlers = {}

        def install(number, handler):
            old = handlers.get(number, signal.SIG_DFL)
            handlers[number] = handler
            return old

        def cancel_after_exit(**kwargs):
            if kwargs["timeout"] == 35:
                handlers[signal.SIGTERM](signal.SIGTERM, None)

        watcher = Mock()
        watcher.join.side_effect = cancel_after_exit
        with patch("run.frozen"), patch("run.verify_runtime", return_value=("owned-device", {})), \
             patch("run.command", return_value=str(container)), patch("run.time.sleep"), \
             patch("run.signal.signal", side_effect=install), patch("run.threading.Thread", return_value=watcher), \
             patch("run.subprocess.Popen", side_effect=[live, video, test]):
            self.assertEqual(run.execute(self.root, products), 1)
        status = json.loads((self.root / "test-status.json").read_text())
        self.assertEqual(status["exit"], 0)
        self.assertEqual(status["signal"], signal.SIGTERM)
        self.assertTrue(status["interrupted"])
        self.assertFalse(run.invocation_succeeded(status))
        self.assertTrue(run.invocation_succeeded({"invoked": True, "exit": 0}))


class ControlCommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.log = Path(temporary.name) / "commands.jsonl"
        log_patch = patch("run.COMMAND_LOG", self.log)
        log_patch.start()
        self.addCleanup(log_patch.stop)

    def test_single_control_call_and_explicit_inventory_keep_bounded_deadlines(self):
        with patch("run.subprocess.check_output", return_value="metadata") as call:
            run.command(["xcrun", "simctl", "list", "devices", "-j"])
            run.command(["xcrun", "simctl", "list", "-j"], timeout=180)
            run.command(["git", "rev-parse", "HEAD"])
        self.assertEqual([c.kwargs["timeout"] for c in call.call_args_list], [90, 180, 30])
        proof = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual([p["timeoutSeconds"] for p in proof], [90, 180, 30])
        self.assertTrue(all(p["status"] == "succeeded" and p["exit"] == 0 for p in proof))
        self.assertTrue(all(p["elapsedSeconds"] >= 0 and p["endedUTC"] >= p["startedUTC"] for p in proof))
        self.assertNotIn("metadata", self.log.read_text())

    def test_timeout_records_failure_without_retry_or_output_disclosure(self):
        error = subprocess.TimeoutExpired("simctl", 90, output="PRIVATE OUTPUT")
        with patch("run.subprocess.check_output", side_effect=error) as call:
            with self.assertRaises(subprocess.TimeoutExpired):
                run.command(["xcrun", "simctl", "getenv", "owned", "SIMULATOR_RUNTIME_BUILD_VERSION"])
        self.assertEqual(call.call_count, 1)
        proof = json.loads(self.log.read_text())
        self.assertEqual(proof["status"], "timeout")
        self.assertIsNone(proof["exit"])
        self.assertNotIn("PRIVATE OUTPUT", self.log.read_text())

    def test_nonzero_control_result_is_retained_and_propagated(self):
        with patch("run.subprocess.check_output", side_effect=subprocess.CalledProcessError(7, "simctl")) as call:
            with self.assertRaises(subprocess.CalledProcessError):
                run.command(["xcrun", "simctl", "create", "owned"])
        self.assertEqual(call.call_count, 1)
        proof = json.loads(self.log.read_text())
        self.assertEqual((proof["status"], proof["exit"]), ("failed", 7))


class RuntimePreflightTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source.txt"
        self.source.write_text("synthetic frozen source")
        self.out = self.root / "evidence"
        self.device = "8C9F4118-331E-4250-B1FC-194972BA6726"
        self.commands = []
        self.runtimes = [{"identifier": run.RUNTIME, "buildversion": build, "isAvailable": True}
                         for build in ("23C52", "23C54")]
        self.actual = "23C54"
        self.query_error = None
        self.query_timeouts = []
        self.name = None
        for mocked in (
            patch.dict("os.environ", EXPECTED_SHA="f" * 40, GITHUB_RUN_ATTEMPT="1"),
            patch("run.command", side_effect=self.command),
            patch("run.subprocess.run", side_effect=self.invoke),
            patch("run.check", return_value=True),
        ):
            mocked.start()
            self.addCleanup(mocked.stop)

    def command(self, args, **_kwargs):
        self.commands.append(args)
        if args[:3] == ["git", "rev-parse", "HEAD"]:
            return "f" * 40 + "\n"
        if args[:3] == ["git", "ls-files", "-z"]:
            return str(self.source) + "\0"
        if args[0] == "git":
            return ""
        if args == ["xcodebuild", "-version"]:
            return "Xcode 27.1\nBuild version 27A9275\n"
        if args == ["xcrun", "simctl", "list", "-j"]:
            return json.dumps({"runtimes": self.runtimes})
        if args[:3] == ["xcrun", "simctl", "create"]:
            self.name = args[3]
            return self.device + "\n"
        if args == ["xcrun", "simctl", "list", "devices", "-j"]:
            return json.dumps({"devices": {run.RUNTIME: [{"udid": self.device, "name": self.name, "state": "Booted"}]}})
        if args == ["xcrun", "simctl", "getenv", self.device, "SIMULATOR_RUNTIME_BUILD_VERSION"]:
            self.query_timeouts.append(_kwargs.get("timeout"))
            if self.query_error is not None:
                raise self.query_error
            return self.actual + "\n"
        raise AssertionError("Unexpected fake command: " + str(args))

    def invoke(self, args, **kwargs):
        self.commands.append(args)
        if args == ["xcrun", "simctl", "bootstatus", self.device, "-b"]:
            kwargs["stdout"].write("Status=4294967295, isTerminal=YES.\nFinished\n")
        else:
            self.assertEqual(args, ["xcrun", "simctl", "shutdown", self.device])
        return subprocess.CompletedProcess(args, 0)

    def test_duplicate_identifier_selects_exact_requested_inventory_build_then_checks_actual(self):
        run.prepare(self.out, True, run.RUNTIME, "23C54")
        identity = json.loads((self.out / "identity.json").read_text())
        selection = json.loads((self.out / "runtime-selection.json").read_text())
        self.assertEqual(len(selection["availableCandidates"]), 2)
        self.assertEqual(selection["exactMatchCount"], 1)
        self.assertEqual(identity["expectedRuntimeBuild"], "23C54")
        self.assertEqual(identity["inventoryRuntimeBuild"], "23C54")
        self.assertEqual(identity["actualRuntimeBuild"], "23C54")
        self.assertTrue(identity["runtimeBuildVerified"])
        self.assertTrue((self.out / "source-sha256.json").exists())
        run.verify_runtime(self.out, "pre-build")
        self.assertEqual(len(list(self.out.glob("runtime-check-*.json"))), 2)

    def test_actual_wrong_build_aborts_before_any_build_test_and_retains_mismatch_for_cleanup(self):
        self.actual = "23C52"
        with self.assertRaisesRegex(ValueError, "expected 23C54, observed '23C52'"):
            run.prepare(self.out, True, run.RUNTIME, "23C54")
        identity = json.loads((self.out / "identity.json").read_text())
        proof = json.loads((self.out / "runtime-check-001.json").read_text())
        self.assertEqual(identity["expectedRuntimeBuild"], "23C54")
        self.assertEqual(identity["actualRuntimeBuild"], "23C52")
        self.assertFalse(proof["matched"])
        self.assertFalse((self.out / "selectors.txt").exists())
        self.assertFalse((self.out / "source-sha256.json").exists())
        self.assertEqual(run.cleanup(self.out), 0)
        self.assertEqual(self.commands[-1], ["xcrun", "simctl", "shutdown", self.device])
        self.assertEqual([a for a in self.commands if a[0] == "xcodebuild"], [["xcodebuild", "-version"]])

    def test_missing_requested_build_refuses_before_device_creation_and_retains_inventory(self):
        self.runtimes = self.runtimes[:1]
        with self.assertRaisesRegex(ValueError, "runtime/build unavailable"):
            run.prepare(self.out, True, run.RUNTIME, "23C54")
        selection = json.loads((self.out / "runtime-selection.json").read_text())
        self.assertEqual(selection["expectedBuild"], "23C54")
        self.assertEqual(selection["exactMatchCount"], 0)
        self.assertFalse(any(a[:3] == ["xcrun", "simctl", "create"] for a in self.commands))
        self.assertFalse((self.out / "identity.json").exists())

    def test_runtime_query_has_one_explicit_bounded_setup_deadline(self):
        run.prepare(self.out, True, run.RUNTIME, "23C54")
        proof = json.loads((self.out / "runtime-check-001.json").read_text())
        self.assertEqual(self.query_timeouts, [90])
        self.assertEqual(proof["queryTimeoutSeconds"], 90)
        self.assertGreaterEqual(proof["queryElapsedSeconds"], 0)
        self.assertTrue(proof["matched"])

    def test_runtime_query_timeout_retains_unknown_and_stops_before_compilation(self):
        self.query_error = subprocess.TimeoutExpired("runtime-query", 90)
        with self.assertRaisesRegex(ValueError, "expected 23C54, observed None"):
            run.prepare(self.out, True, run.RUNTIME, "23C54")
        proof = json.loads((self.out / "runtime-check-001.json").read_text())
        self.assertEqual(self.query_timeouts, [90])
        self.assertIsNone(proof["actualBuild"])
        self.assertFalse(proof["matched"])
        self.assertIn("90 seconds", proof["queryError"])
        self.assertFalse((self.out / "source-sha256.json").exists())
        self.assertFalse((self.out / "selectors.txt").exists())
        self.assertEqual([a for a in self.commands if a[0] == "xcodebuild"], [["xcodebuild", "-version"]])

    def test_local_build_is_explicit_and_representative_cannot_substitute(self):
        with self.assertRaisesRegex(ValueError, "explicit expected runtime build"):
            run.prepare(self.out, True, run.RUNTIME)
        with self.assertRaisesRegex(ValueError, "exact iOS26.2/23C54"):
            run.prepare(self.root / "representative", False, run.RUNTIME, "23C52")
        self.assertEqual(self.commands, [])


class SourcePreservationTests(unittest.TestCase):
    def test_overlay_reduces_to_exact_b359_sources(self):
        self.assertTrue(preservation.check(Path(__file__).resolve().parents[2]))

    def test_original_assertion_or_button_geometry_change_is_detected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = Path(__file__).resolve().parents[2]
            for name in preservation.ORIGINAL:
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source / name, root / name)
            theme = root / "ios/App/Theme.swift"
            theme.write_text(theme.read_text().replace("minWidth: 44", "minWidth: 1"))
            with self.assertRaises(ValueError):
                preservation.check(root)


if __name__ == "__main__":
    unittest.main()
