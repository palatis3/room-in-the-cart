import unittest
from unittest.mock import Mock

from check_native_backend import NoRedirect, check, signing_key


class NativeBackendTests(unittest.TestCase):
    def setUp(self):
        self.config = {"supabaseURL": "https://identity.invalid", "publishableKey": "public-fixture",
                       "serviceURL": "https://household.invalid", "emailOTPEnabled": False}
        self.settings = {"external": {"email": True}, "disable_signup": False, "mailer_autoconfirm": False}
        self.keys = {"keys": [{"kty": "EC", "crv": "P-256", "alg": "ES256", "kid": "fixture", "x": "x", "y": "y"}]}
        self.session = {"available": False, "authenticated": False}

    def probe(self):
        fetch = Mock(side_effect=[self.settings, self.keys, {"status": "running"}, self.session])
        result = check(self.config, "Staging", fetch)
        self.assertEqual([call.args[1] for call in fetch.call_args_list],
                         [{"apikey": "public-fixture"}, {}, {}, {}])
        return result

    def test_configured_staging_with_disabled_email(self):
        self.assertFalse(self.probe())

    def test_email_disagreement_and_non_boolean_status(self):
        for wrong in (True, 0, None):
            self.session["available"] = wrong
            with self.assertRaisesRegex(ValueError, "does not match"):
                self.probe()

    def test_email_verification_and_supported_key_required(self):
        self.settings["mailer_autoconfirm"] = True
        with self.assertRaisesRegex(ValueError, "verification"):
            self.probe()
        self.settings["mailer_autoconfirm"] = False
        self.keys["keys"][0].pop("x")
        with self.assertRaisesRegex(ValueError, "signing key"):
            self.probe()
        self.assertFalse(signing_key({"alg": "RS256", "kty": "RSA", "kid": "x"}))
        self.assertTrue(signing_key({"alg": "RS256", "kty": "RSA", "kid": "x", "n": "n", "e": "e"}))

    def test_empty_release_and_disabled_release_fail_before_network(self):
        for config, expected in (({}, "missing"), (self.config, "disabled")):
            with self.assertRaisesRegex(ValueError, expected):
                check(config, "Release", lambda *_: self.fail("Unexpected network request"))

    def test_redirect_never_forwards_headers(self):
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))


if __name__ == "__main__":
    unittest.main()
