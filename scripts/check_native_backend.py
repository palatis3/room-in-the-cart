#!/usr/bin/env python3
"""Check the public endpoints used by a configured native build."""
import argparse
import json
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from app_configuration import load_configuration


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_json(url, headers):
    opener = build_opener(NoRedirect())
    with opener.open(Request(url, headers=headers), timeout=15) as response:
        limit = 65536
        data = response.read(limit + 1)
        if (response.status != 200 or len(data) > limit
                or response.headers.get_content_type() != "application/json"):
            raise ValueError("Expected a bounded JSON response")
        payload = json.loads(data)
        if not isinstance(payload, dict):
            raise ValueError("Expected a JSON object")
        return payload


def signing_key(key):
    if not isinstance(key, dict) or key.get("use", "sig") != "sig":
        return False
    if key.get("alg") == "ES256" and key.get("kty") == "EC" and key.get("crv") == "P-256":
        fields = ("kid", "x", "y")
    elif key.get("alg") == "RS256" and key.get("kty") == "RSA":
        fields = ("kid", "n", "e")
    else:
        return False
    return all(isinstance(key.get(field), str) and key[field].strip() for field in fields)


def check(config, name, fetch=fetch_json):
    missing = [key for key in ("supabaseURL", "publishableKey", "serviceURL") if not config.get(key)]
    if missing:
        raise ValueError(f"{name} configuration is missing " + ", ".join(missing))
    enabled = config.get("emailOTPEnabled") is True
    if name == "Release" and not enabled:
        raise ValueError("Release email-code sign-in is disabled")
    auth = config["supabaseURL"].rstrip("/") + "/auth/v1"
    service = config["serviceURL"].rstrip("/")
    settings = fetch(auth + "/settings", {"apikey": config["publishableKey"]})
    providers = settings.get("external")
    if (not isinstance(providers, dict) or providers.get("email") is not True
            or settings.get("disable_signup") is not False or settings.get("mailer_autoconfirm") is not False):
        raise ValueError("Supabase email account creation and verification settings do not match the app")
    keys = fetch(auth + "/.well-known/jwks.json", {}).get("keys")
    if not isinstance(keys, list) or not any(signing_key(key) for key in keys):
        raise ValueError("Supabase did not advertise a supported public signing key")
    if fetch(service + "/health", {}).get("status") != "running":
        raise ValueError("The household service did not report running")
    session = fetch(service + "/v1/auth/session", {})
    if session.get("available") is not enabled or session.get("authenticated") is not False:
        raise ValueError("The household service email sign-in setting does not match the native build")
    return enabled


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("configuration", choices=("Staging", "Release"))
    name = parser.parse_args().configuration
    try:
        enabled = check(load_configuration(Path(__file__).resolve().parents[1], name), name)
    except (ValueError, OSError, URLError) as error:
        print(f"{name} backend check failed: {error}", file=sys.stderr)
        return 1
    print(f"{name} public endpoints passed. Email-code entry is {'enabled' if enabled else 'disabled'}.")
    print("Code delivery, signed sessions and household writes require a separate account walkthrough.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
