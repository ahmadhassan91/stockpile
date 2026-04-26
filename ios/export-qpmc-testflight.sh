#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="$ROOT_DIR/StockpileCaptureApp.xcodeproj"
SCHEME_NAME="StockpileCaptureApp"
BUILD_DIR="${ROOT_DIR}/build"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to export the iOS alpha archive." >&2
  exit 1
fi

TEAM_ID="${STOCKPILE_DEVELOPMENT_TEAM:-}"
EXPORT_METHOD="${STOCKPILE_EXPORT_METHOD:-app-store}"
EXPORT_DIR="${STOCKPILE_EXPORT_DIR:-$BUILD_DIR/export}"
UPLOAD_SYMBOLS="${STOCKPILE_UPLOAD_SYMBOLS:-YES}"
MANAGE_VERSION_AND_BUILD="${STOCKPILE_MANAGE_VERSION_AND_BUILD:-NO}"
COMPILE_BITCODE="${STOCKPILE_COMPILE_BITCODE:-NO}"
STRIP_SWIFT_SYMBOLS="${STOCKPILE_STRIP_SWIFT_SYMBOLS:-YES}"

usage() {
  cat <<'EOF'
Usage:
  STOCKPILE_DEVELOPMENT_TEAM=ABCDE12345 \
  ./ios/export-qpmc-testflight.sh ios/build/StockpileCaptureApp.xcarchive

Optional overrides:
  STOCKPILE_EXPORT_METHOD=app-store
  STOCKPILE_EXPORT_DIR=ios/build/export
  STOCKPILE_UPLOAD_SYMBOLS=YES
  STOCKPILE_MANAGE_VERSION_AND_BUILD=NO
  STOCKPILE_COMPILE_BITCODE=NO
  STOCKPILE_STRIP_SWIFT_SYMBOLS=YES
EOF
}

if [[ "${1:-}" == "--help" || $# -eq 0 ]]; then
  usage
  exit 0
fi

ARCHIVE_PATH="$1"

if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "Archive not found: $ARCHIVE_PATH" >&2
  exit 1
fi

if [[ -z "$TEAM_ID" ]]; then
  echo "STOCKPILE_DEVELOPMENT_TEAM is required." >&2
  usage
  exit 1
fi

mkdir -p "$EXPORT_DIR"

EXPORT_OPTIONS_PLIST="$(mktemp /tmp/stockpile-export-options.XXXXXX.plist)"
cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>${EXPORT_METHOD}</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>destination</key>
  <string>export</string>
  <key>manageAppVersionAndBuildNumber</key>
  <$( [[ "$MANAGE_VERSION_AND_BUILD" == "YES" ]] && echo true || echo false )/>
  <key>uploadSymbols</key>
  <$( [[ "$UPLOAD_SYMBOLS" == "YES" ]] && echo true || echo false )/>
  <key>compileBitcode</key>
  <$( [[ "$COMPILE_BITCODE" == "YES" ]] && echo true || echo false )/>
  <key>stripSwiftSymbols</key>
  <$( [[ "$STRIP_SWIFT_SYMBOLS" == "YES" ]] && echo true || echo false )/>
</dict>
</plist>
EOF

echo "Exporting archive:"
echo "  Archive: $ARCHIVE_PATH"
echo "  Export:  $EXPORT_DIR"
echo "  Method:  $EXPORT_METHOD"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -exportPath "$EXPORT_DIR"

rm -f "$EXPORT_OPTIONS_PLIST"

cat <<EOF

Export completed:
  $EXPORT_DIR

Next step:
  Upload the exported app with Xcode Organizer or Transporter using the same Apple team/app record.
EOF
