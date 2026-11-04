"""Public native build configuration. Never read deployment secrets here."""
import ipaddress
import json
import re
import unicodedata
from urllib.parse import urlsplit

PUBLIC_SETTINGS = (
    ("RITC_SUPABASE_URL", "supabaseURL", "SupabaseProjectURL"),
    ("RITC_SUPABASE_PUBLISHABLE_KEY", "publishableKey", "SupabasePublishableKey"),
    ("RITC_SERVICE_URL", "serviceURL", "HouseholdServiceURL"),
    ("RITC_HOUSEHOLD_SUBSCRIPTION_PRODUCT_ID", "householdSubscriptionProductID", "HouseholdSubscriptionProductID"),
    ("RITC_PRIVACY_POLICY_URL", "privacyPolicyURL", "PrivacyPolicyURL"),
    ("RITC_TERMS_OF_USE_URL", "termsOfUseURL", "TermsOfUseURL"),
    ("RITC_SUPPORT_URL", "supportURL", "SupportURL"),
    ("RITC_SUPPORT_EMAIL", "supportEmail", "SupportEmail"),
    ("RITC_OPERATOR_NAME", "operatorName", "OperatorName"),
    ("RITC_HELP_URL", "helpURL", "HelpURL"),
)
PAGE_KEYS = {"privacyPolicyURL", "termsOfUseURL", "supportURL", "helpURL"}
BACKEND_URL_KEYS = ("supabaseURL", "serviceURL")
HTTPS_AUTHORITY = re.compile(r"(?:\[[0-9a-fA-F:.]+\]|[^:\[\]]+)(?::[0-9]+)?")
DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
RELEASE_METADATA = ("HouseholdSubscriptionProductID", "PrivacyPolicyURL", "TermsOfUseURL", "SupportURL")
NONPUBLIC_PAGE_DOMAINS = ("alt", "arpa", "example", "example.com", "example.net", "example.org",
                          "internal", "invalid", "local", "localhost", "onion", "test")
IPV4_PROTOCOL_ADDRESSES = ipaddress.ip_network("192.0.0.0/24")
IPV4_PUBLIC_EXCEPTIONS = {ipaddress.ip_address("192.0.0.9"), ipaddress.ip_address("192.0.0.10")}
IPV4_RETIRED_RELAY = ipaddress.ip_network("192.88.99.0/24")
IPV6_PUBLIC_UNICAST = ipaddress.ip_network("2000::/3")
IPV6_PROTOCOL_ADDRESSES = ipaddress.ip_network("2001::/23")
IPV6_PUBLIC_EXCEPTIONS = tuple(map(ipaddress.ip_network, (
    "2001:1::1/128", "2001:1::2/128", "2001:1::3/128", "2001:3::/32", "2001:4:112::/48",
    "2001:20::/28", "2001:30::/28",
)))
IPV6_SPECIAL_NONPUBLIC = tuple(map(ipaddress.ip_network, ("2002::/16", "3fff::/20")))
IPV6_TRANSLATION_PREFIX = ipaddress.ip_network("64:ff9b::/96")


def valid_operator_name(value):
    return (isinstance(value, str) and bool(value) and value == value.strip()
            and len(value.encode("utf-8")) <= 300 and "$(" not in value
            and not any(unicodedata.category(char) in ("Cc", "Cf", "Zl", "Zp") for char in value))


def valid_support_email(value):
    if not isinstance(value, str) or len(value) > 254:
        return False
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+", value):
        return False
    local, domain = value.split("@")
    return len(local) <= 64 and not local.endswith(".") and ".." not in local and all(len(label) <= 63 for label in domain.split("."))


def valid_page_address(address):
    # macOS system Python and CI can have different ipaddress registry data.
    if isinstance(address, ipaddress.IPv6Address):
        if address.ipv4_mapped is not None:
            address = address.ipv4_mapped
        elif address in IPV6_TRANSLATION_PREFIX:
            address = ipaddress.IPv4Address(int(address) & 0xffffffff)
        else:
            if address in IPV6_PROTOCOL_ADDRESSES:
                return any(address in network for network in IPV6_PUBLIC_EXCEPTIONS)
            return (address in IPV6_PUBLIC_UNICAST and address.is_global
                    and not any(address in network for network in IPV6_SPECIAL_NONPUBLIC))
    if address in IPV4_PROTOCOL_ADDRESSES:
        return address in IPV4_PUBLIC_EXCEPTIONS
    return address.is_global and not address.is_multicast and address not in IPV4_RETIRED_RELAY


def valid_page_url(value):
    if not isinstance(value, str) or not value or "$(" in value or "\\" in value:
        return False
    if any(char.isspace() or unicodedata.category(char) in ("Cc", "Cf") for char in value):
        return False
    try:
        url = urlsplit(value)
        if url.scheme != "https" or url.username is not None or url.password is not None:
            return False
        if not HTTPS_AUTHORITY.fullmatch(url.netloc) or url.port == 0:
            return False
        host = (url.hostname or "").encode("idna").decode("ascii").lower().removesuffix(".")
    except ValueError:
        return False
    if any(host == domain or host.endswith("." + domain) for domain in NONPUBLIC_PAGE_DOMAINS):
        return False
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        labels = host.split(".")
        return (len(labels) > 1 and len(host) <= 253 and labels[-1][:1].isalpha()
                and all(DNS_LABEL.fullmatch(label) for label in labels))
    return valid_page_address(address)


def backend_origin(value):
    if any(char.isspace() or unicodedata.category(char) in ("Cc", "Cf") for char in value):
        raise ValueError("Invalid HTTPS endpoint")
    url = urlsplit(value)
    if (url.scheme != "https" or not url.hostname or url.username is not None
            or any(char in value for char in "\\?#") or "%" in url.netloc or not url.netloc.isascii()
            or not HTTPS_AUTHORITY.fullmatch(url.netloc) or url.port == 0):
        raise ValueError("Invalid HTTPS endpoint")
    host = url.hostname.lower().removesuffix(".")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        labels = host.split(".")
        # Use ASCII DNS labels, including punycode, and reject ambiguous IPv4 spellings.
        if (len(host) > 253 or not all(DNS_LABEL.fullmatch(label) for label in labels)
                or re.fullmatch(r"(?:[0-9]+|0x[0-9a-f]*)", labels[-1])):
            raise ValueError("Invalid HTTPS endpoint") from None
    else:
        if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
            address = address.ipv4_mapped
        host = address.compressed
    return host, url.port or 443


def load_configuration(root, name):
    if name not in ("Debug", "Staging", "Release"):
        raise ValueError("Unknown native build configuration")
    # A Release build must never inherit the staging service, public key or URLs.
    path = root / "config" / ("release.json" if name == "Release" else "staging.json")
    config = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(config, dict):
        raise ValueError(f"{path.name} must contain a JSON object")
    contact_path = root / "config/public-contact.json"
    contact = json.loads(contact_path.read_text()) if contact_path.exists() else {}
    if not isinstance(contact, dict):
        raise ValueError("public-contact.json must contain a JSON object")
    for key in ("supportEmail", "operatorName"):
        if key not in config and key in contact:
            config[key] = contact[key]
    expected_environment = "production" if name == "Release" else "staging"
    if config.get("environment", expected_environment) != expected_environment:
        raise ValueError(f"{path.name} must identify the {expected_environment} environment")
    if "emailOTPEnabled" in config and not isinstance(config["emailOTPEnabled"], bool):
        raise ValueError("emailOTPEnabled must be a JSON boolean")
    origins = {}
    for _, key, _ in PUBLIC_SETTINGS:
        value = config.get(key, "")
        if not isinstance(value, str) or value != value.strip() or "$(" in value:
            raise ValueError(f"{key} must be a literal public string without surrounding whitespace")
        if value and key in PAGE_KEYS and not valid_page_url(value):
            raise ValueError(f"{key} must be an operator-owned HTTPS page, without credentials or a test/example host")
        if value and key in BACKEND_URL_KEYS:
            try:
                origins[key] = backend_origin(value)
            except ValueError:
                raise ValueError(f"{key} must be an HTTPS endpoint with an ASCII hostname or IP and no credentials, query or fragment") from None
        if value and key == "publishableKey" and not re.fullmatch(r"sb_publishable_[A-Za-z0-9_-]+", value):
            raise ValueError("publishableKey must be a Supabase sb_publishable_ client key")
        if key == "householdSubscriptionProductID" and value and any(char.isspace() for char in value):
            raise ValueError("householdSubscriptionProductID cannot contain whitespace")
        if key == "supportEmail" and value and not valid_support_email(value):
            raise ValueError("supportEmail must be a bare address without headers, query, whitespace or encoded characters")
        if key == "operatorName" and value and not valid_operator_name(value):
            raise ValueError("operatorName must be a bounded literal name without control or format characters")
    if name == "Release" and (origins or config.get("publishableKey")):
        staging = load_configuration(root, "Staging")
        for key, origin in origins.items():
            if staging.get(key) and origin == backend_origin(staging[key]):
                raise ValueError(f"release.json {key} must use an origin separate from staging")
        if config.get("publishableKey") and config["publishableKey"] == staging.get("publishableKey"):
            raise ValueError("release.json publishableKey must be separate from staging")
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
