"""Check the reviewed data declarations and required-reason APIs in both app profiles."""
from pathlib import Path
import plistlib


def verify_app_privacy_manifests(ios):
    functionality = {"AppFunctionality"}
    analytics = {"AppFunctionality", "Analytics"}
    personalized = {"AppFunctionality", "Analytics", "ProductPersonalization"}
    private = {
        "EmailAddress": functionality, "EmailsOrTextMessages": functionality, "CustomerSupport": functionality,
        "SearchHistory": analytics, "OtherDiagnosticData": analytics,
    }
    connected = {
        **private, "Name": functionality, "UserID": personalized, "DeviceID": functionality,
        "OtherUserContent": personalized, "PhotosorVideos": functionality, "AudioData": functionality,
        "OtherFinancialInfo": functionality, "ProductInteraction": functionality, "PurchaseHistory": analytics,
    }
    apis = {
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["3B52.1", "C617.1"],
    }
    for profile, declarations in (("Private", private), ("Connected", connected)):
        path = ios / "Resources/Privacy" / profile / "PrivacyInfo.xcprivacy"
        with path.open("rb") as handle:
            manifest = plistlib.load(handle)
        if manifest.get("NSPrivacyTracking") is not False or manifest.get("NSPrivacyTrackingDomains"):
            raise ValueError(f"{profile}: unexpected tracking declaration")
        accessed = manifest["NSPrivacyAccessedAPITypes"]
        if (len(accessed) != len(apis) or
                {row["NSPrivacyAccessedAPIType"]: sorted(row["NSPrivacyAccessedAPITypeReasons"])
                 for row in accessed} != apis):
            raise ValueError(f"{profile}: required-reason API declarations differ")
        rows = manifest["NSPrivacyCollectedDataTypes"]
        expected = {"NSPrivacyCollectedDataType" + k: sorted("NSPrivacyCollectedDataTypePurpose" + p for p in v)
                    for k, v in declarations.items()}
        if (len(rows) != len(expected) or
                {row["NSPrivacyCollectedDataType"]: sorted(row["NSPrivacyCollectedDataTypePurposes"])
                 for row in rows} != expected or
                any(row["NSPrivacyCollectedDataTypeLinked"] is not True or
                    row["NSPrivacyCollectedDataTypeTracking"] is not False for row in rows)):
            raise ValueError(f"{profile}: collected data declarations differ")


if __name__ == "__main__":
    verify_app_privacy_manifests(Path(__file__).resolve().parents[1] / "ios")
