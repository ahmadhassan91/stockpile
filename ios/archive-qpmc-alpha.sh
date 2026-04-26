#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="$ROOT_DIR/StockpileCaptureApp.xcodeproj"
SCHEME_NAME="StockpileCaptureApp"
BUILD_DIR="${ROOT_DIR}/build"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to archive the iOS alpha." >&2
  exit 1
fi

TEAM_ID="${STOCKPILE_DEVELOPMENT_TEAM:-}"
BUILD_NUMBER="${STOCKPILE_BUILD_NUMBER:-}"
MARKETING_VERSION="${STOCKPILE_MARKETING_VERSION:-}"
BUNDLE_ID="${STOCKPILE_PRODUCT_BUNDLE_IDENTIFIER:-com.clustox.stockpile.capture}"
API_BASE_URL="${STOCKPILE_API_BASE_URL:-https://stockpile.theclustox.com/api/mobile}"
API_BEARER_TOKEN="${STOCKPILE_API_BEARER_TOKEN:-}"
API_AUTH_HEADER_NAME="${STOCKPILE_API_AUTH_HEADER_NAME:-}"
API_AUTH_HEADER_VALUE="${STOCKPILE_API_AUTH_HEADER_VALUE:-}"
ARCHIVE_NAME="${STOCKPILE_ARCHIVE_NAME:-StockpileCaptureApp}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-YES}"

usage() {
  cat <<'EOF'
Usage:
  STOCKPILE_DEVELOPMENT_TEAM=ABCDE12345 \
  STOCKPILE_BUILD_NUMBER=12 \
  ./ios/archive-qpmc-alpha.sh

Optional overrides:
  STOCKPILE_MARKETING_VERSION=0.1.0
  STOCKPILE_PRODUCT_BUNDLE_IDENTIFIER=com.example.bundle
  STOCKPILE_API_BASE_URL=https://host/api/mobile
  STOCKPILE_API_BEARER_TOKEN=...
  STOCKPILE_API_AUTH_HEADER_NAME=x-api-key
  STOCKPILE_API_AUTH_HEADER_VALUE=...
  STOCKPILE_ARCHIVE_NAME=StockpileCaptureApp-QPMC
  ALLOW_PROVISIONING_UPDATES=NO
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "STOCKPILE_DEVELOPMENT_TEAM is required." >&2
  usage
  exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  echo "STOCKPILE_BUILD_NUMBER is required." >&2
  usage
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "Generating Xcode project..."
"$ROOT_DIR/generate-project.sh" >/tmp/stockpile-generate-project.log

echo "Running readiness check..."
"$ROOT_DIR/check-testflight-readiness.sh"

ARCHIVE_PATH="$BUILD_DIR/${ARCHIVE_NAME}.xcarchive"
rm -rf "$ARCHIVE_PATH"

echo "Archiving Release build to:"
echo "  $ARCHIVE_PATH"

XC_ARGS=(
  -project "$PROJECT_FILE"
  -scheme "$SCHEME_NAME"
  -configuration Release
  -destination "generic/platform=iOS"
  -archivePath "$ARCHIVE_PATH"
  archive
  "STOCKPILE_DEVELOPMENT_TEAM=$TEAM_ID"
  "STOCKPILE_BUILD_NUMBER=$BUILD_NUMBER"
  "STOCKPILE_PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID"
  "STOCKPILE_API_BASE_URL=$API_BASE_URL"
)

if [[ -n "$MARKETING_VERSION" ]]; then
  XC_ARGS+=("STOCKPILE_MARKETING_VERSION=$MARKETING_VERSION")
fi

if [[ -n "$API_BEARER_TOKEN" ]]; then
  XC_ARGS+=("STOCKPILE_API_BEARER_TOKEN=$API_BEARER_TOKEN")
fi

if [[ -n "$API_AUTH_HEADER_NAME" ]]; then
  XC_ARGS+=("STOCKPILE_API_AUTH_HEADER_NAME=$API_AUTH_HEADER_NAME")
fi

if [[ -n "$API_AUTH_HEADER_VALUE" ]]; then
  XC_ARGS+=("STOCKPILE_API_AUTH_HEADER_VALUE=$API_AUTH_HEADER_VALUE")
fi

if [[ "$ALLOW_PROVISIONING_UPDATES" == "YES" ]]; then
  XC_ARGS+=(-allowProvisioningUpdates)
fi

xcodebuild "${XC_ARGS[@]}"

cat <<EOF

Archive created successfully:
  $ARCHIVE_PATH

Next step:
  STOCKPILE_DEVELOPMENT_TEAM=$TEAM_ID \\
  ./ios/export-qpmc-testflight.sh "$ARCHIVE_PATH"
EOF
