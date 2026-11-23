import unittest
from unittest.mock import Mock

from check_native_backend import NoRedirect, check, has_signing_key


class NativeBackendTests(unittest.TestCase):
    def setUp(self):
        self.config = {"supabaseURL": "https://identity.invalid", "publishableKey": "public-fixture",
                       "serviceURL": "https://household.invalid", "emailOTPEnabled": False}
        self.settings = {"external": {"email": True}, "disable_signup": False, "mailer_autoconfirm": False}
        self.keys = {"keys": [{"kty": "EC", "crv": "P-256", "alg": "ES256", "kid": "fixture", "x": "axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpY",
                               "y": "T-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU"}]}
        self.session = {"available": False, "authenticated": False}

    def probe(self, name="Staging", **options):
        fetch = Mock(side_effect=[self.settings, self.keys, {"status": "running"}, self.session])
        result = check(self.config, name, fetch, **options)
        self.assertEqual([call.args[1] for call in fetch.call_args_list],
                         [{"apikey": "public-fixture"}, {}, {}, {}])
        return result

    def test_configured_staging_with_disabled_email(self):
        self.assertFalse(self.probe())
        self.settings["disable_signup"] = True
        self.assertFalse(self.probe())

    def test_disabled_staging_still_requires_an_explicit_signup_setting(self):
        del self.settings["disable_signup"]
        with self.assertRaisesRegex(ValueError, "account creation"):
            self.probe()

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
        self.assertFalse(has_signing_key([{"alg": "RS256", "kty": "RSA", "kid": "x"}]))
        self.assertFalse(has_signing_key([{"alg": "ES256", "kty": "EC", "crv": "P-256",
                                           "kid": "bad-point", "x": "x", "y": "y"}]))

    def test_empty_release_and_disabled_release_fail_before_network(self):
        for config, expected in (({}, "missing"), (self.config, "disabled")):
            with self.assertRaisesRegex(ValueError, expected):
                check(config, "Release", lambda *_: self.fail("Unexpected network request"))

    def test_existing_accounts_only_requires_explicit_selection(self):
        self.config["emailOTPEnabled"] = True
        self.session["available"] = True
        self.assertTrue(self.probe("Release"))
        self.settings.update(disable_signup=True, saml_enabled=False, passkeys_enabled=False)
        self.settings["external"].update(anonymous_users=False, phone=False, github=False)
        self.assertTrue(self.probe("Release", existing_accounts_only=True))
        with self.assertRaisesRegex(ValueError, "account creation"):
            self.probe("Release")
        self.session["available"] = False
        with self.assertRaisesRegex(ValueError, "household service"):
            self.probe("Release", existing_accounts_only=True)

    def test_existing_accounts_only_rejects_ambiguous_or_open_provider_configuration(self):
        with self.assertRaisesRegex(ValueError, "disabled"):
            self.probe(existing_accounts_only=True)
        self.config["emailOTPEnabled"] = True
        self.session["available"] = True
        self.settings.update(disable_signup=True, saml_enabled=False, passkeys_enabled=False)
        providers = self.settings["external"]
        providers.update(anonymous_users=False, phone=False)
        for target, key, value in ((self.settings, "disable_signup", False), (self.settings, "disable_signup", 1),
                                    (self.settings, "mailer_autoconfirm", True), (providers, "email", False),
                                    (providers, "anonymous_users", True), (providers, "phone", None),
                                    (providers, "github", True), (self.settings, "saml_enabled", True),
                                    (self.settings, "passkeys_enabled", "false")):
            with self.subTest(key=key, value=value), unittest.mock.patch.dict(target, {key: value}):
                with self.assertRaises(ValueError):
                    self.probe("Release", existing_accounts_only=True)
        del providers["anonymous_users"]
        with self.assertRaises(ValueError):
            self.probe("Release", existing_accounts_only=True)

    def test_redirect_never_forwards_headers(self):
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))


if __name__ == "__main__":
    unittest.main()
