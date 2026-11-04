#!/usr/bin/env python3
"""Check staging authentication boundaries and, optionally, the deployed web build."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
WEB_ROUTES = ("help", "privacy", "terms", "support", "requests", "invite", "view", "child-invite")
ASSET_TYPES = {
    ".css": ("text/css",),
    ".js": ("application/javascript", "text/javascript"),
    ".png": ("image/png",),
}


def fetch(url, headers=None):
    try:
        return urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=20)
    except urllib.error.HTTPError as error:
        return error


def api_checks(base, email_enabled):
    cases = [
        ("health", "/health", {}, 200, {"status": "running"}),
        ("session", "/v1/session", {}, 200, {"authenticated": False}),
        ("email-availability", "/v1/auth/session", {}, 200, {"available": email_enabled, "authenticated": False}),
        ("unauthenticated", "/v1/me/workspaces", {}, 401, None),
        ("invalid-token", "/v1/me/workspaces", {"Authorization": "Bearer invalid"}, 401, None),
        ("wrong-origin", "/v1/session", {"Origin": "https://example.invalid"}, 403, None),
    ]
    for name, path, headers, expected, fields in cases:
        with fetch(base + path, headers) as response:
            try:
                payload = json.loads(response.read(65_536))
            except (UnicodeError, json.JSONDecodeError):
                payload = None
            passed = (
                response.status == expected
                and response.geturl() == base + path
                and isinstance(payload, dict)
                and all(payload.get(key) == value for key, value in (fields or {}).items())
                and response.headers.get_content_type() == "application/json"
                and response.headers.get("Cache-Control") == "no-store"
            )
            yield {"check": name, "path": path, "status": response.status, "expected": expected, "pass": passed}


def web_checks(base, directory):
    shell = (directory / "index.html").read_bytes()
    assets = sorted(path for path in directory.rglob("*") if path.is_file() and path.suffix in ASSET_TYPES)
    if b'id="app"' not in shell or not any(path.suffix == ".js" for path in assets):
        raise ValueError("Expected the compiled Room in the Cart web output")

    pages = ["/"] + [f"/{name}{suffix}" for name in WEB_ROUTES for suffix in ("", "/")]
    files = [(path, shell, ("text/html",)) for path in pages]
    files += [("/" + path.relative_to(directory).as_posix(), path.read_bytes(), ASSET_TYPES[path.suffix]) for path in assets]
    for path, expected, content_types in files:
        with fetch(base + path) as response:
            actual = response.read(len(expected) + 1)
            allowed_urls = {base + path}
            if path in pages and path != "/":
                canonical = base + path.rstrip("/")
                allowed_urls.update((canonical, canonical + "/"))
            passed = (
                response.status == 200
                and response.geturl() in allowed_urls
                and response.headers.get_content_type() in content_types
                and response.headers.get("Referrer-Policy") == "no-referrer"
                and actual == expected
            )
            yield {
                "check": "candidate-web", "path": path, "status": response.status,
                "expected": 200, "pass": passed,
                "expectedSHA256": hashlib.sha256(expected).hexdigest(),
            }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-build", type=Path, help="require the exact compiled web output at all staging routes")
    parser.add_argument("--evidence", type=Path, default=ROOT / "docs/evidence/staging-public-smoke.json")
    args = parser.parse_args()
    configuration = json.loads((ROOT / "config/staging.json").read_text())
    base = configuration["serviceURL"].rstrip("/")
    if not base.startswith("https://"):
        parser.error("Staging checks require HTTPS")
    checks = list(api_checks(base, configuration.get("emailOTPEnabled") is True))
    if args.web_build is not None:
        checks.extend(web_checks(base, args.web_build))
    evidence = {"checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "url": base, "checks": checks}
    args.evidence.write_text(json.dumps(evidence, indent=2) + "\n")
    for result in checks:
        print(result["check"], result["path"], "PASS" if result["pass"] else "FAIL", result["status"])
    return 0 if all(result["pass"] for result in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
