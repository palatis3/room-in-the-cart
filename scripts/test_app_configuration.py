import json
from pathlib import Path
import tempfile
import unittest

from app_configuration import (PUBLIC_SETTINGS, build_settings, compiled_metadata,
                               load_configuration, require_release_metadata, valid_page_url)


class AppConfigurationTests(unittest.TestCase):
    def test_release_does_not_inherit_staging(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            (root / "config/staging.json").write_text(json.dumps({"serviceURL": "https://staging.grocery-app.com", "publishableKey": "staging-public-key", "supportURL": "https://staging.grocery-app.com/support"}))
            self.assertEqual(load_configuration(root, "Release"), {})
            release = compiled_metadata(load_configuration(root, "Release"), "Release")
            self.assertEqual(release["HouseholdServiceURL"], "")
            self.assertEqual(release["SupportURL"], "")
            self.assertEqual(release["SupabasePublishableKey"], "")
            self.assertEqual(release["RITCBuildEnvironment"], "Release")

    def test_all_public_fields_reach_build_settings_and_plist_expectations(self):
        config = {key: "value-" + key for _, key, _ in PUBLIC_SETTINGS}
        config["emailOTPEnabled"] = True
        settings = build_settings(config, "Staging")
        metadata = compiled_metadata(config, "Staging")
        for setting, key, info in PUBLIC_SETTINGS:
            self.assertEqual(settings[setting], config[key])
            self.assertEqual(metadata[info], config[key])
        self.assertEqual(settings["RITC_EMAIL_OTP_ENABLED"], "YES")
        self.assertEqual(metadata["RITCEmailOTPEnabled"], "YES")

    def test_config_uses_allowlist_and_never_exports_unrelated_secrets(self):
        config = {"databasePassword": "private", "serviceRoleKey": "private", "publishableKey": "public"}
        self.assertNotIn("private", build_settings(config, "Debug").values())
        self.assertNotIn("private", compiled_metadata(config, "Debug").values())

    def test_https_pages_reject_credentials_placeholders_and_test_hosts(self):
        self.assertTrue(valid_page_url("https://support.grocery-app.com/es/help?language=es#account"))
        for value in ("", "http://support.grocery-app.com", "https://user:secret@support.grocery-app.com", "https://localhost/help", "https://example.com/help", "https://sub.example.org", "https://support.invalid", "https://support.test", "$(RITC_SUPPORT_URL)", " https://support.grocery-app.com", "https://[invalid"):
            with self.subTest(value=value):
                self.assertFalse(valid_page_url(value))

    def test_wrong_environment_and_nonliteral_values_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            path = root / "config/release.json"
            for config in ({"environment": "staging"}, {"supportURL": "https://support.invalid"}, {"privacyPolicyURL": "$(PRIVACY_URL)"}, {"emailOTPEnabled": "false"}, {"householdSubscriptionProductID": "product annual"}, {"termsOfUseURL": 42}):
                with self.subTest(config=config):
                    path.write_text(json.dumps(config))
                    with self.assertRaises(ValueError):
                        load_configuration(root, "Release")

    def test_explicit_release_file_and_metadata_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            config = {"environment": "production", "householdSubscriptionProductID": "com.grocery-app.household.annual", "privacyPolicyURL": "https://grocery-app.com/privacy", "termsOfUseURL": "https://grocery-app.com/terms", "supportURL": "https://grocery-app.com/support"}
            (root / "config/release.json").write_text(json.dumps(config))
            info = compiled_metadata(load_configuration(root, "Release"), "Release")
            require_release_metadata(info)
            info["SupportURL"] = ""
            with self.assertRaisesRegex(ValueError, "SupportURL"):
                require_release_metadata(info)
            info["SupportURL"] = "https://support.invalid"
            with self.assertRaisesRegex(ValueError, "SupportURL"):
                require_release_metadata(info)


if __name__ == "__main__":
    unittest.main()
