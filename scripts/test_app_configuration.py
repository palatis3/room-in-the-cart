import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

from app_configuration import (PUBLIC_SETTINGS, build_settings, compiled_metadata,
                               load_configuration, require_release_metadata, valid_page_url, valid_support_email, valid_operator_name)
from check_built_app import verify_built_app


class AppConfigurationTests(unittest.TestCase):
    def test_release_does_not_inherit_staging(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            (root / "config/staging.json").write_text(json.dumps({"serviceURL": "https://staging.grocery-app.com", "publishableKey": "sb_publishable_staging", "supportURL": "https://staging.grocery-app.com/support"}))
            self.assertEqual(load_configuration(root, "Release"), {})
            release = compiled_metadata(load_configuration(root, "Release"), "Release")
            self.assertEqual(release["HouseholdServiceURL"], "")
            self.assertEqual(release["SupportURL"], "")
            self.assertEqual(release["SupabasePublishableKey"], "")
            self.assertEqual(release["RITCBuildEnvironment"], "Release")

    def test_release_backend_origins_and_client_key_must_differ_from_staging(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            staging = {
                "environment": "staging", "supabaseURL": "https://staging-auth.grocery-app.com",
                "serviceURL": "https://staging-service.grocery-app.com", "publishableKey": "sb_publishable_staging",
                "supportURL": "https://grocery-app.com/support",
            }
            release = {
                **staging, "environment": "production", "supabaseURL": "https://auth.grocery-app.com",
                "serviceURL": "https://service.grocery-app.com", "publishableKey": "sb_publishable_production",
            }
            (root / "config/staging.json").write_text(json.dumps(staging))
            path = root / "config/release.json"
            path.write_text(json.dumps(release))
            self.assertEqual(load_configuration(root, "Release"), release)
            self.assertEqual(load_configuration(root, "Staging"), staging)
            for key, aliases in {
                "supabaseURL": (staging["supabaseURL"], "https://STAGING-AUTH.grocery-app.com.:443/subpath"),
                "serviceURL": (staging["serviceURL"], "https://Staging-Service.grocery-app.com:443/another-path"),
                "publishableKey": (staging["publishableKey"],),
            }.items():
                for value in aliases:
                    with self.subTest(key=key, value=value):
                        path.write_text(json.dumps({**release, key: value}))
                        with self.assertRaisesRegex(ValueError, key + ".*separate from staging"):
                            load_configuration(root, "Release")
            release["serviceURL"] = "https://staging-service.grocery-app.com:8443"
            path.write_text(json.dumps(release))
            self.assertEqual(load_configuration(root, "Release"), release)
            staging["serviceURL"] = "https://8.8.8.8"
            (root / "config/staging.json").write_text(json.dumps(staging))
            path.write_text(json.dumps({**release, "serviceURL": "https://[::ffff:8.8.8.8]:443"}))
            with self.assertRaisesRegex(ValueError, "serviceURL.*separate from staging"):
                load_configuration(root, "Release")

    def test_nonempty_backend_values_must_be_safe_for_the_native_client(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            path = root / "config/staging.json"
            for key, values in {
                "supabaseURL": ("http://auth.grocery-app.com", "https://user:password@auth.grocery-app.com", "https://auth.grocery-app.com:0", "https://faß.de"),
                "serviceURL": ("https://service.grocery-app.com?", "https://service.grocery-app.com#route", "https://%73ervice.grocery-app.com", "https://134744072", "https://0x08080808", "https://8.8.2056"),
                "publishableKey": ("sb_secret_fixture", "eyJfixture.jwt.signature", "sb_publishable_", "sb_publishable_bad\nkey"),
            }.items():
                for value in values:
                    with self.subTest(key=key, value=value):
                        path.write_text(json.dumps({key: value}))
                        with self.assertRaisesRegex(ValueError, key):
                            load_configuration(root, "Staging")
            config = {"supabaseURL": "https://xn--fa-hia.de", "serviceURL": "https://[::1]:8443/api", "publishableKey": "sb_publishable_fixture-1"}
            path.write_text(json.dumps(config))
            self.assertEqual(load_configuration(root, "Staging"), config)

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

    def test_https_pages_reject_nonpublic_hosts_and_ambiguous_url_syntax(self):
        for value in (
            "https://127.0.0.1/help", "https://127.1/help", "https://[::1]/help", "https://10.0.0.4/privacy",
            "https://[::ffff:127.0.0.1]/help", "https://224.0.0.1/help", "https://staging.local/support",
            "https://example.com./privacy", "https://router.home.arpa/support", "https://intranet/support",
            "https://grocery-app.com:99999/support", "https://grocery-app.com:0/support", "https://grocery-app.com:/support",
            "https://grocery-app.com/te\nrms", "https://grocery-app.com\\bad/support", "https://grocery-app.com/te\u202erms",
            "https://[2606:4700::1111]garbage/support", "https://grocery-app..com/support",
            "https://[fec0::1]/help", "https://[4000::1]/help", "https://[3fff::1]/help",
            "https://192.0.0.8/help", "https://192.88.99.2/help", "https://[64:ff9b::7f00:1]/help",
        ):
            with self.subTest(value=value):
                self.assertFalse(valid_page_url(value))
        for value in (
            "HTTPS://support.grocery-app.com.:8443/es/help?language=es#account",
            "https://ayúda.grocery-app.com/privacidad", "https://[2606:4700::1111]/support",
            "https://8.8.8.8/help", "https://[::ffff:8.8.8.8]/help",
            "https://192.0.0.9/help", "https://[2001:3::1]/help", "https://[64:ff9b::808:808]/help",
        ):
            with self.subTest(value=value):
                self.assertTrue(valid_page_url(value))

    def test_user_supplied_public_contact_reaches_all_environments_without_staging_fallback(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            (root / "config/public-contact.json").write_text(json.dumps({"supportEmail": "hello@roominthecart.com", "operatorName": "Venture House Group LLC", "secret": "not-exported"}))
            for name in ("Debug", "Staging", "Release"):
                config = load_configuration(root, name)
                self.assertEqual(config, {"supportEmail": "hello@roominthecart.com", "operatorName": "Venture House Group LLC"})
                self.assertEqual(compiled_metadata(config, name)["SupportEmail"], "hello@roominthecart.com")
                self.assertEqual(compiled_metadata(config, name)["OperatorName"], "Venture House Group LLC")
                self.assertEqual(compiled_metadata(config, name)["HouseholdServiceURL"], "")

    def test_support_email_rejects_headers_queries_and_encoded_newlines(self):
        self.assertTrue(valid_support_email("hello@roominthecart.com"))
        for value in ("hello@roominthecart.com\nBcc:other@roominthecart.com", "hello@roominthecart.com?subject=hello", "hello%0d%0a@roominthecart.com", "mailto:hello@roominthecart.com", "hello@roominthecart.com#body", " hello@roominthecart.com", "hello..other@roominthecart.com", "hello@-roominthecart.com", "hello@roominthecart..com", "hello@roominthecart.com\r"):
            with self.subTest(value=value):
                self.assertFalse(valid_support_email(value))

    def test_operator_name_preserves_supplied_literal_and_rejects_controls(self):
        self.assertTrue(valid_operator_name("Venture House Group LLC"))
        for value in (None, "", " Venture House Group LLC", "Venture House Group LLC ", "Venture\nHouse Group LLC", "Venture\tHouse Group LLC", "Venture\x00House Group LLC", "Venture\u202eHouse Group LLC", "Venture\u2028House Group LLC", "$(OPERATOR_NAME)", "a" * 301):
            with self.subTest(value=value):
                self.assertFalse(valid_operator_name(value))

    def test_wrong_environment_and_nonliteral_values_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "config").mkdir()
            path = root / "config/release.json"
            for config in ({"environment": "staging"}, {"supportURL": "https://support.invalid"}, {"privacyPolicyURL": "$(PRIVACY_URL)"}, {"emailOTPEnabled": "false"}, {"householdSubscriptionProductID": "product annual"}, {"termsOfUseURL": 42}, {"operatorName": "Venture\nHouse Group LLC"}):
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
            info["SupportURL"] = "https://127.0.0.1/support"
            with self.assertRaisesRegex(ValueError, "SupportURL"):
                require_release_metadata(info)


class BuiltAppVerificationTests(unittest.TestCase):
    root = Path(__file__).resolve().parents[1]

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.path = Path(folder.name)
        self.app = self.make_app("Release", "dev.roominthecart.app", "roominthecart", "iPhoneOS")
        self.widget = self.app / "PlugIns/RoomInTheCartWidget.appex"
        self.share = self.app / "PlugIns/RoomInTheCartShare.appex"

    def make_app(self, configuration, bundle_id, scheme, platform):
        app = self.path / configuration / "RoomInTheCart.app"
        widget_group = f"group.{bundle_id}.widget"
        share_group = f"group.{bundle_id}.share-inbox"
        purpose = {key: "Permission purpose" for key in (
            "NSFaceIDUsageDescription", "NSCameraUsageDescription",
            "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription",
        )}
        common = {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
                  "CFBundleSupportedPlatforms": [platform], "UIDeviceFamily": [1], "MinimumOSVersion": "17.0"}
        bundles = {
            app: {
                **compiled_metadata(load_configuration(self.root, configuration), configuration),
                **purpose,
                "CFBundleIdentifier": bundle_id,
                "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
                "CFBundleURLTypes": [{"CFBundleTypeRole": "Editor", "CFBundleURLName": bundle_id + ".surface",
                                      "CFBundleURLSchemes": [scheme]}],
                "RITCWidgetAppGroup": widget_group,
                "RITCShareInboxAppGroup": share_group,
                "RITCSurfaceURLScheme": scheme,
            },
            app / "PlugIns/RoomInTheCartWidget.appex": {
                "CFBundleIdentifier": bundle_id + ".widget", "CFBundleDisplayName": "Widget",
                "RITCWidgetAppGroup": widget_group, "RITCSurfaceURLScheme": scheme,
                "NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
            },
            app / "PlugIns/RoomInTheCartShare.appex": {
                "CFBundleIdentifier": bundle_id + ".share", "CFBundleDisplayName": "Share",
                "RITCShareInboxAppGroup": share_group,
                "NSExtension": {"NSExtensionPointIdentifier": "com.apple.share-services",
                                "NSExtensionAttributes": {"NSExtensionActivationRule": {
                                    "NSExtensionActivationSupportsText": True}}},
            },
        }
        for bundle, metadata in bundles.items():
            bundle.mkdir(parents=True)
            executable = bundle / bundle.stem
            executable.write_bytes(b"fixture executable")
            executable.chmod(0o755)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                **common, **metadata, "CFBundleExecutable": bundle.stem,
            }))
        (app / "Assets.car").write_bytes(b"fixture asset catalog")
        shutil.copyfile(self.root / "ios/Resources/PrivacyInfo.xcprivacy", app / "PrivacyInfo.xcprivacy")
        for language in ("en", "es"):
            localized = app / f"{language}.lproj"
            localized.mkdir()
            (localized / "InfoPlist.strings").write_bytes(plistlib.dumps(purpose))
        return app

    def expect_plist_rejected(self, bundle, changes, message):
        plist = bundle / "Info.plist"
        original = plist.read_bytes()
        try:
            plist.write_bytes(plistlib.dumps({**plistlib.loads(original), **changes}))
            with self.assertRaisesRegex(ValueError, message):
                verify_built_app(self.app, "Release")
        finally:
            plist.write_bytes(original)

    def test_valid_release_staging_and_debug_test_host(self):
        verify_built_app(self.app, "Release")
        staging = self.make_app("Staging", "dev.roominthecart.app.staging", "roominthecart-staging", "iPhoneOS")
        verify_built_app(staging, "Staging")
        debug = self.make_app("Debug", "dev.roominthecart.app.debug", "roominthecart-debug", "iPhoneSimulator")
        (debug / "PlugIns/RoomInTheCartTests.xctest").mkdir()
        verify_built_app(debug, "Debug")

    def test_rejects_incorrect_device_family_floor_and_platform(self):
        for bundle in (self.app, self.widget, self.share):
            with self.subTest(bundle=bundle.name):
                self.expect_plist_rejected(bundle, {"UIDeviceFamily": [1, 2]}, "must target iPhone only")
                self.expect_plist_rejected(bundle, {"MinimumOSVersion": "18.0"}, "must support iOS 17.0")
                self.expect_plist_rejected(bundle, {"CFBundleSupportedPlatforms": ["MacOSX"]}, "must be built for iPhone")
        self.expect_plist_rejected(self.share, {"CFBundleSupportedPlatforms": ["iPhoneSimulator"]}, "platform mismatch")

    def test_rejects_missing_executables_and_assets_even_with_python_optimization(self):
        for executable in (self.app / "RoomInTheCart", self.widget / "RoomInTheCartWidget",
                           self.share / "RoomInTheCartShare"):
            with self.subTest(executable=executable.name):
                executable.chmod(0o644)
                with self.assertRaisesRegex(ValueError, "Missing or nonexecutable bundle executable"):
                    verify_built_app(self.app, "Release")
                executable.chmod(0o755)
        (self.app / "Assets.car").unlink()
        result = subprocess.run([sys.executable, "-B", "-O", str(self.root / "scripts/check_built_app.py"),
                                 str(self.app), "--configuration", "Release"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing compiled asset catalog", result.stderr)

    def test_rejects_release_url_scheme_and_group_from_another_environment(self):
        self.expect_plist_rejected(self.app, {"RITCSurfaceURLScheme": "roominthecart-debug"}, "Wrong app URL scheme")
        self.expect_plist_rejected(self.app, {"CFBundleURLTypes": [{
            "CFBundleTypeRole": "Editor", "CFBundleURLName": "dev.roominthecart.app.surface",
            "CFBundleURLSchemes": ["roominthecart", "roominthecart-debug"],
        }]}, "Wrong app URL scheme registration")
        self.expect_plist_rejected(self.widget, {"RITCSurfaceURLScheme": "roominthecart-debug"}, "Wrong Widget extension URL scheme")
        self.expect_plist_rejected(self.widget, {"RITCShareInboxAppGroup": "group.dev.roominthecart.app.share-inbox"},
                                   "Widget extension received another surface's container")
        # Agreement between the host and its extension is insufficient if both use the wrong group.
        key = "RITCWidgetAppGroup"
        wrong_group = "group.dev.roominthecart.app.debug.widget"
        widget_info = self.widget / "Info.plist"
        widget_info.write_bytes(plistlib.dumps({**plistlib.loads(widget_info.read_bytes()), key: wrong_group}))
        self.expect_plist_rejected(self.app, {key: wrong_group}, "Wrong app container")
        with self.assertRaisesRegex(ValueError, "Wrong Widget extension container"):
            verify_built_app(self.app, "Release")

    def test_rejects_incompatible_extension_version_and_overbroad_share_activation(self):
        self.expect_plist_rejected(self.widget, {"CFBundleShortVersionString": "0.2.0"}, "Widget extension version mismatch")
        self.expect_plist_rejected(self.share, {"CFBundleVersion": "999"}, "Share extension version mismatch")
        for rule in ("TRUEPREDICATE", {"NSExtensionActivationSupportsText": True,
                                       "NSExtensionActivationSupportsImageWithMaxCount": 1}):
            with self.subTest(rule=rule):
                self.expect_plist_rejected(self.share, {"NSExtension": {
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionAttributes": {"NSExtensionActivationRule": rule},
                }}, "Share extension must activate for text only")

    def test_rejects_test_bundles_in_release_including_the_known_debug_unit_bundle(self):
        for bundle in (self.app / "PlugIns/RoomInTheCartTests.xctest", self.share / "LeakedFixture.xctest"):
            with self.subTest(bundle=bundle.name):
                bundle.mkdir()
                with self.assertRaisesRegex(ValueError, "Unexpected test bundle"):
                    verify_built_app(self.app, "Release")
                bundle.rmdir()


if __name__ == "__main__":
    unittest.main()
