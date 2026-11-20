#!/usr/bin/env python3
"""Check the public endpoints used by a configured native build."""
import argparse
import json
import subprocess
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


# Use the household service's Node WebCrypto implementation to reject malformed
# EC points, incompatible key usages and undersized RSA verification keys.
IMPORT_SIGNING_KEYS = """
const { readFileSync } = require('node:fs');
const { subtle } = require('node:crypto').webcrypto;
const keys = JSON.parse(readFileSync(0, 'utf8'));
(async () => {
    for (const jwk of keys) {
        if (!jwk || typeof jwk.kid !== 'string' || !jwk.kid.trim() || jwk.d ||
            (jwk.use !== undefined && jwk.use !== 'sig')) continue;
        let algorithm;
        if (jwk.alg === 'ES256') algorithm = { name: 'ECDSA', namedCurve: 'P-256' };
        else if (jwk.alg === 'RS256') algorithm = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' };
        else continue;
        try {
            const key = await subtle.importKey('jwk', jwk, algorithm, false, ['verify']);
            if (key.type === 'public' && (jwk.alg !== 'RS256' || key.algorithm.modulusLength >= 2048)) return;
        } catch { /* A key rotation may also advertise an unsupported key. */ }
    }
    process.exitCode = 1;
})();
"""


def has_signing_key(keys):
    if not isinstance(keys, list) or not keys:
        return False
    try:
        result = subprocess.run(["node", "-e", IMPORT_SIGNING_KEYS], input=json.dumps(keys),
                                text=True, capture_output=True, timeout=10)
    except FileNotFoundError:
        raise ValueError("Add the repository's Node runtime to PATH to check public signing keys") from None
    except subprocess.TimeoutExpired:
        raise ValueError("Public signing key validation timed out") from None
    return result.returncode == 0


def check(config, name, fetch=fetch_json, *, existing_accounts_only=False):
    missing = [key for key in ("supabaseURL", "publishableKey", "serviceURL") if not config.get(key)]
    if missing:
        raise ValueError(f"{name} configuration is missing " + ", ".join(missing))
    enabled = config.get("emailOTPEnabled") is True
    if (name == "Release" or existing_accounts_only) and not enabled:
        raise ValueError(f"{name} email-code sign-in is disabled")
    auth = config["supabaseURL"].rstrip("/") + "/auth/v1"
    service = config["serviceURL"].rstrip("/")
    settings = fetch(auth + "/settings", {"apikey": config["publishableKey"]})
    providers = settings.get("external")
    if (not isinstance(providers, dict) or providers.get("email") is not True
            or settings.get("disable_signup") is not existing_accounts_only or settings.get("mailer_autoconfirm") is not False):
        raise ValueError("Supabase email account creation and verification settings do not match the app")
    if existing_accounts_only and (
        providers.get("anonymous_users") is not False or providers.get("phone") is not False
        or any(value is not False for key, value in providers.items() if key != "email")
        or settings.get("saml_enabled") is not False or settings.get("passkeys_enabled") is not False
    ):
        raise ValueError("The private review environment must advertise email as its only sign-in method")
    keys = fetch(auth + "/.well-known/jwks.json", {}).get("keys")
    if not has_signing_key(keys):
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
    parser.add_argument("--existing-accounts-only", action="store_true",
                        help="Check a private review environment with email sign-in enabled and public signup disabled")
    args = parser.parse_args()
    name = args.configuration
    try:
        enabled = check(load_configuration(Path(__file__).resolve().parents[1], name), name,
                        existing_accounts_only=args.existing_accounts_only)
    except (ValueError, OSError, URLError) as error:
        print(f"{name} backend check failed: {error}", file=sys.stderr)
        return 1
    print(f"{name} public endpoints passed. Email-code entry is {'enabled' if enabled else 'disabled'}.")
    if args.existing_accounts_only:
        print("The provider advertises email sign-in for existing accounts with public signup disabled.")
    print("Code delivery, signed sessions and household writes require a separate account walkthrough.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
