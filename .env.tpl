# Operator/CI bootstrap manifest. These values never enter the browser bundle.
# Mint for Iris; do not copy another project's credential.
CLOUDFLARE_API_TOKEN="op://Life UI/Life UI CI Cloudflare Token/api-token"
CLOUDFLARE_ACCOUNT_ID="op://Life UI/Life UI CI Cloudflare Token/account-id"

# Shared Apple signing exception. Used only by distribution workflows.
DEVELOPER_ID_P12_BASE64="op://Apple Signing/Developer ID Application Cert/p12_base64"
DEVELOPER_ID_P12_PASSWORD="op://Apple Signing/Developer ID Application Cert/password"
ASC_KEY_P8_BASE64="op://Apple Signing/App Store Connect API Key/p8_base64"
ASC_KEY_ID="op://Apple Signing/App Store Connect API Key/key_id"
ASC_ISSUER_ID="op://Apple Signing/App Store Connect API Key/issuer_id"
TAP_PUSH_TOKEN="op://Apple Signing/Homebrew Tap Push Token/token"

IOS_CERTIFICATE_P12_BASE64="op://Apple Signing/Apple Distribution Cert/p12_base64"
IOS_CERTIFICATE_PASSWORD="op://Apple Signing/Apple Distribution Cert/password"
IOS_PROFILE_BASE64="op://Apple Signing/Wildcard Ad Hoc Profile/mobileprovision_base64"
IOS_DEVICE_ID="op://Life UI/Life UI ENV/IOS_DEVICE_ID"
