"""Public native build configuration. Never read deployment secrets here."""
import json
from urllib.parse import urlsplit

PUBLIC_SETTINGS = (
    ("RITC_SUPABASE_URL", "supabaseURL", "SupabaseProjectURL"),
    ("RITC_SUPABASE_PUBLISHABLE_KEY", "publishableKey", "SupabasePublishableKey"),
    ("RITC_SERVICE_URL", "serviceURL", "HouseholdServiceURL"),
    ("RITC_HOUSEHOLD_SUBSCRIPTION_PRODUCT_ID", "householdSubscriptionProductID", "HouseholdSubscriptionProductID"),
    ("RITC_PRIVACY_POLICY_URL", "privacyPolicyURL", "PrivacyPolicyURL"),
    ("RITC_TERMS_OF_USE_URL", "termsOfUseURL", "TermsOfUseURL"),
    ("RITC_SUPPORT_URL", "supportURL", "SupportURL"),
    ("RITC_HELP_URL", "helpURL", "HelpURL"),
)
PAGE_KEYS = {"privacyPolicyURL", "termsOfUseURL", "supportURL", "helpURL"}
RELEASE_METADATA = ("HouseholdSubscriptionProductID", "PrivacyPolicyURL", "TermsOfUseURL", "SupportURL")


def valid_page_url(value):
    if not isinstance(value, str) or not value or value != value.strip() or "$(" in value:
        return False
    try:
        url = urlsplit(value)
        host = (url.hostname or "").lower()
        reserved = ("example.com", "example.org", "example.net")
        return (url.scheme.lower() == "https" and bool(host) and url.username is None and url.password is None
                and host != "localhost" and not host.endswith((".invalid", ".test"))
                and not any(host == domain or host.endswith("." + domain) for domain in reserved))
    except ValueError:
        return False


def load_configuration(root, name):
    if name not in ("Debug", "Staging", "Release"):
        raise ValueError("Unknown native build configuration")
    # A Release build must never inherit the staging service, public key or URLs.
    path = root / "config" / ("release.json" if name == "Release" else "staging.json")
    config = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(config, dict):
        raise ValueError(f"{path.name} must contain a JSON object")
    expected_environment = "production" if name == "Release" else "staging"
    if config.get("environment", expected_environment) != expected_environment:
        raise ValueError(f"{path.name} must identify the {expected_environment} environment")
    if "emailOTPEnabled" in config and not isinstance(config["emailOTPEnabled"], bool):
        raise ValueError("emailOTPEnabled must be a JSON boolean")
    for _, key, _ in PUBLIC_SETTINGS:
        value = config.get(key, "")
        if not isinstance(value, str) or value != value.strip() or "$(" in value:
            raise ValueError(f"{key} must be a literal public string without surrounding whitespace")
        if value and key in PAGE_KEYS and not valid_page_url(value):
            raise ValueError(f"{key} must be an operator-owned HTTPS page, without credentials or a test/example host")
        if key == "householdSubscriptionProductID" and value and any(char.isspace() for char in value):
            raise ValueError("householdSubscriptionProductID cannot contain whitespace")
    return config


def build_settings(config, name):
    return {
        **{setting: config.get(key, "") for setting, key, _ in PUBLIC_SETTINGS},
        "RITC_EMAIL_OTP_ENABLED": "YES" if config.get("emailOTPEnabled") is True else "NO",
        "RITC_BUILD_ENVIRONMENT": name,
    }


def compiled_metadata(config, name):
    return {
        **{info_key: config.get(key, "") for _, key, info_key in PUBLIC_SETTINGS},
        "RITCEmailOTPEnabled": "YES" if config.get("emailOTPEnabled") is True else "NO",
        "RITCBuildEnvironment": name,
    }


def require_release_metadata(info):
    missing = [key for key in RELEASE_METADATA if not info.get(key)]
    if missing:
        raise ValueError("Release metadata is incomplete: " + ", ".join(missing))
    for key in RELEASE_METADATA:
        if key.endswith("URL") and not valid_page_url(info[key]):
            raise ValueError(f"Release metadata has an invalid {key}")
