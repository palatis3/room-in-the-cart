#!/usr/bin/env python3
"""Check deployed staging availability and authentication boundaries without a login."""
import datetime
import json
from pathlib import Path
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[1]
configuration = json.loads((root / "config/staging.json").read_text())
base = configuration["serviceURL"]
assert base.startswith("https://"), "Staging checks require HTTPS"
checks = [
    ("health", "/health", {}, 200, {"status": "running"}),
    ("session", "/v1/session", {}, 200, {"authenticated": False}),
    ("email-availability", "/v1/auth/session", {}, 200, {"available": configuration.get("emailOTPEnabled") is True, "authenticated": False}),
    ("unauthenticated", "/v1/me/workspaces", {}, 401, None),
    ("invalid-token", "/v1/me/workspaces", {"Authorization": "Bearer invalid"}, 401, None),
    ("wrong-origin", "/v1/session", {"Origin": "https://example.invalid"}, 403, None),
]
results = []
for name, path, headers, expected, fields in checks:
    try:
        response = urllib.request.urlopen(urllib.request.Request(base + path, headers=headers), timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        payload = json.loads(response.read(65_536))
        passed = response.status == expected and all(payload.get(key) == value for key, value in (fields or {}).items())
        passed = passed and response.headers.get_content_type() == "application/json" and response.headers.get("Cache-Control") == "no-store"
        results.append({"check": name, "path": path, "status": response.status, "expected": expected, "pass": passed})
evidence = {"checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "url": base, "checks": results}
(root / "docs/evidence/staging-public-smoke.json").write_text(json.dumps(evidence, indent=2) + "\n")
for result in results:
    print(result["check"], "PASS" if result["pass"] else "FAIL", result["status"])
assert all(result["pass"] for result in results), "Staging boundary check failed"
