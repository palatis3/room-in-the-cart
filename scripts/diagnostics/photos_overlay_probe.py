from pathlib import Path
import hashlib
import json
import os
import shutil
import signal
import subprocess
import time
import zipfile


evidence_root = Path(os.environ["EVIDENCE"]).resolve()
codeql_executable = Path(os.environ["CODEQL_DIR"]) / "codeql"
fixture_path = evidence_root / "source/PhotoProbe.swift"
query_path = evidence_root / "queries/Probe.ql"
experiment_started = time.monotonic()
variant_results = []


def run_command(arguments, log_path, timeout_seconds, environment=None):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    command_started = time.monotonic()
    with log_path.open("w") as log_stream:
        process = subprocess.Popen(
            arguments,
            stdout=log_stream,
            stderr=subprocess.STDOUT,
            env=environment,
            start_new_session=True,
        )
        try:
            exit_code = process.wait(
                timeout=max(
                    1,
                    min(
                        timeout_seconds,
                        620 - (time.monotonic() - experiment_started),
                    ),
                )
            )
            timed_out = False
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            exit_code = process.returncode
            timed_out = True

    command_result = {
        "argv": arguments,
        "exitCode": exit_code,
        "timeout": timed_out,
        "seconds": round(time.monotonic() - command_started, 3),
        "log": str(log_path.relative_to(evidence_root)),
    }
    log_path.with_suffix(".command.json").write_text(
        json.dumps(command_result, indent=2)
    )
    return command_result


for variant in ("baseline", "enabled"):
    variant_directory = evidence_root / variant
    variant_directory.mkdir()
    database_path = variant_directory / "database"
    variant_environment = dict(
        os.environ,
        VARIANT=variant,
        VARIANT_DIR=str(variant_directory),
    )
    creation_result = run_command(
        [
            str(codeql_executable),
            "database",
            "create",
            str(database_path),
            "--language=swift",
            "--source-root=" + str(evidence_root / "source"),
            "--threads=2",
            "--ram=4096",
            "--command=bash " + str(evidence_root / "compile.sh"),
        ],
        variant_directory / "create.log",
        220,
        variant_environment,
    )
    variant_result = {
        "variant": variant,
        "create": creation_result,
        "query": None,
        "rows": None,
        "sourceVerified": False,
    }

    # Retain actual extractor invocations and errors even if creation did not finish.
    if (database_path / "log").is_dir():
        shutil.copytree(
            database_path / "log",
            variant_directory / "database-logs",
        )
    extractor_invocations = []
    for extractor_log in (variant_directory / "database-logs").rglob("*.log"):
        for line in extractor_log.read_text(errors="replace").splitlines():
            if (
                "calling extractor with arguments" in line
                and "-module-name PhotoProbe" in line
            ):
                extractor_invocations.append(line)
    (variant_directory / "extractor-invocations.json").write_text(
        json.dumps(extractor_invocations, indent=2)
    )
    variant_result["flagForwardingVerified"] = bool(extractor_invocations) and all(
        ("-enable-cross-import-overlays" in line) == (variant == "enabled")
        for line in extractor_invocations
    )

    for filename in ("codeql-database.yml", "src.zip"):
        if (database_path / filename).is_file():
            shutil.copy2(database_path / filename, variant_directory / filename)
    if (variant_directory / "src.zip").is_file():
        with zipfile.ZipFile(variant_directory / "src.zip") as source_archive:
            fixture_entries = [
                entry
                for entry in source_archive.namelist()
                if entry == "PhotoProbe.swift" or entry.endswith("/PhotoProbe.swift")
            ]
            source_hashes = {
                entry: hashlib.sha256(source_archive.read(entry)).hexdigest()
                for entry in fixture_entries
            }
            (variant_directory / "source-archive-hashes.json").write_text(
                json.dumps(source_hashes, indent=2)
            )
            variant_result["sourceVerified"] = (
                len(source_hashes) == 1
                and next(iter(source_hashes.values()))
                == hashlib.sha256(fixture_path.read_bytes()).hexdigest()
            )

    if creation_result["exitCode"] == 0 and not creation_result["timeout"]:
        bqrs_path = variant_directory / "probe.bqrs"
        variant_result["query"] = run_command(
            [
                str(codeql_executable),
                "query",
                "run",
                "--database=" + str(database_path),
                "--output=" + str(bqrs_path),
                "--threads=2",
                "--ram=4096",
                str(query_path),
            ],
            variant_directory / "query.log",
            80,
        )
        if (
            variant_result["query"]["exitCode"] == 0
            and not variant_result["query"]["timeout"]
        ):
            decoded_path = variant_directory / "probe.json"
            decoding_result = run_command(
                [
                    str(codeql_executable),
                    "bqrs",
                    "decode",
                    str(bqrs_path),
                    "--format=json",
                    "--output=" + str(decoded_path),
                ],
                variant_directory / "decode.log",
                15,
            )
            variant_result["decode"] = decoding_result
            if decoding_result["exitCode"] == 0:
                variant_result["rows"] = json.loads(decoded_path.read_text())[
                    "#select"
                ]["tuples"]

    (variant_directory / "result.json").write_text(
        json.dumps(variant_result, indent=2)
    )
    variant_results.append(variant_result)

# No expected-success assertion: an unchanged error or failed trial is a valid
# diagnostic outcome. Missing extraction/query/source proof makes the comparison
# explicitly inconclusive.
comparison_complete = all(
    result["create"]["exitCode"] == 0
    and result["query"]
    and result["query"]["exitCode"] == 0
    and result["rows"] is not None
    and result["sourceVerified"]
    and result["flagForwardingVerified"]
    for result in variant_results
)
summary = {
    "schemaVersion": 1,
    "candidate": os.environ["EXPECTED_SHA"],
    "fixtureSHA256": hashlib.sha256(fixture_path.read_bytes()).hexdigest(),
    "completeComparison": comparison_complete,
    "variants": variant_results,
    "countsAsCandidateAcceptance": False,
    "limits": [
        "Tiny fixture only; no app coverage or MembershipView claim.",
        "Flag improvement is established only if baseline has picker errors, "
        "enabled clears them, and enabled references resolve to both picker "
        "declarations.",
        "Global SDK declarations alone do not count; query resolution rows are "
        "restricted to PhotoProbe.swift.",
    ],
}
for result in variant_results:
    rows = result["rows"] or []
    result["compilerErrors"] = [
        row[1] for row in rows if row[0] == "compiler-error"
    ]
    result["resolvedPickerNames"] = sorted(
        set(row[1] for row in rows if row[0].startswith("resolved-"))
    )
summary["supportsFlagHypothesis"] = bool(
    comparison_complete
    and any(
        "PhotosPicker" in error
        for error in variant_results[0]["compilerErrors"]
    )
    and not variant_results[1]["compilerErrors"]
    and variant_results[1]["resolvedPickerNames"]
    == ["PhotosPicker", "PhotosPickerItem"]
)
(evidence_root / "comparison.json").write_text(json.dumps(summary, indent=2))
print(
    json.dumps(
        {
            "completeComparison": comparison_complete,
            "supportsFlagHypothesis": summary["supportsFlagHypothesis"],
            "variants": [
                {
                    "variant": result["variant"],
                    "errors": result["compilerErrors"],
                    "resolved": result["resolvedPickerNames"],
                }
                for result in variant_results
            ],
        },
        indent=2,
    )
)
