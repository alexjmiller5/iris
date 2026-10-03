# Operator/CI bootstrap manifest. These values never enter the browser bundle.
# Mint for Life UI; do not copy another project's credential.
CLOUDFLARE_API_TOKEN="op://Life UI/Life UI CI Cloudflare Token/api-token"
CLOUDFLARE_ACCOUNT_ID="op://Life UI/Life UI CI Cloudflare Token/account-id"

# Shared Apple signing exception. Used only by the Mac release workflow.
DEVELOPER_ID_P12_BASE64="op://Apple Signing/Developer ID Application Cert/p12_base64"
DEVELOPER_ID_P12_PASSWORD="op://Apple Signing/Developer ID Application Cert/password"
ASC_KEY_P8_BASE64="op://Apple Signing/App Store Connect API Key/p8_base64"
ASC_KEY_ID="op://Apple Signing/App Store Connect API Key/key_id"
ASC_ISSUER_ID="op://Apple Signing/App Store Connect API Key/issuer_id"
TAP_PUSH_TOKEN="op://Apple Signing/Homebrew Tap Push Token/token"
