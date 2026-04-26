#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_SPEC="$ROOT_DIR/project.yml"
PROJECT_FILE="$ROOT_DIR/StockpileCaptureApp.xcodeproj"
PBXPROJ="$PROJECT_FILE/project.pbxproj"
SCHEME_FILE="$PROJECT_FILE/xcshareddata/xcschemes/StockpileCaptureApp.xcscheme"
SCHEME_NAME="StockpileCaptureApp"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to inspect Release build settings." >&2
  exit 1
fi

if [[ ! -f "$PROJECT_SPEC" ]]; then
  echo "Missing XcodeGen spec at $PROJECT_SPEC" >&2
  exit 1
fi

if [[ ! -f "$PBXPROJ" ]]; then
  echo "Missing generated project at $PBXPROJ" >&2
  echo "Run ./ios/generate-project.sh first." >&2
  exit 1
fi

if [[ ! -f "$SCHEME_FILE" ]]; then
  echo "Missing shared scheme at $SCHEME_FILE" >&2
  echo "Regenerate the project with ./ios/generate-project.sh before archiving." >&2
  exit 1
fi

BUILD_SETTINGS="$(
  xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -showBuildSettings 2>/dev/null
)"

extract_setting() {
  local key="$1"
  printf '%s\n' "$BUILD_SETTINGS" | sed -n "s/^[[:space:]]*${key} = //p" | head -n 1
}

status=0
pass_count=0
warn_count=0
fail_count=0
pass_items=()
warn_items=()
fail_items=()
manual_items=(
  "Produce a signed Release archive with the real Apple team and App Store Connect app record."
  "Run at least one physical iPhone capture from start through upload, processing, and a real terminal review outcome."
  "Test upload interruption and relaunch behavior on-device at least once."
  "Verify operator-facing review guidance for verified, review_only, and blocked on real backend results."
  "Do not archive with legacy demo overrides or fallback-capture overrides such as STOCKPILE_LAUNCH_MODE=review_presentation, STOCKPILE_REVIEW_PRESENTATION=YES, STOCKPILE_USE_MOCK_RESULTS=YES, STOCKPILE_ENABLE_BACKUP_VIDEO_IMPORT=YES, STOCKPILE_ENABLE_CONFIGURED_FALLBACK_CAPTURE=YES, or STOCKPILE_CAPTURE_FILE_PATH/URL."
  "Record the evidence packet: version/build, commit, backend URL, device matrix, and durable IDs from one real run."
)

pass() {
  ((pass_count += 1))
  pass_items+=("$1")
}

warn() {
  ((warn_count += 1))
  warn_items+=("$1")
}

fail() {
  ((fail_count += 1))
  fail_items+=("$1")
  status=1
}

print_section() {
  local title="$1"
  shift
  local items=("$@")

  printf '%s\n' "$title"
  if [[ "${#items[@]}" -eq 0 || ( "${#items[@]}" -eq 1 && -z "${items[0]}" ) ]]; then
    printf '  - none\n'
  else
    local item
    for item in "${items[@]}"; do
      printf '  - %s\n' "$item"
    done
  fi
  echo
}

bundle_id="$(extract_setting PRODUCT_BUNDLE_IDENTIFIER)"
team_id="$(extract_setting DEVELOPMENT_TEAM)"
code_sign_style="$(extract_setting CODE_SIGN_STYLE)"
marketing_version="$(extract_setting MARKETING_VERSION)"
build_number="$(extract_setting CURRENT_PROJECT_VERSION)"
environment_name="$(extract_setting STOCKPILE_ENVIRONMENT)"
api_base_url="$(extract_setting STOCKPILE_API_BASE_URL)"
launch_mode="$(extract_setting STOCKPILE_LAUNCH_MODE)"
use_live_camera="$(extract_setting STOCKPILE_USE_LIVE_CAMERA)"
use_mock_results="$(extract_setting STOCKPILE_USE_MOCK_RESULTS)"
backup_video_import="$(extract_setting STOCKPILE_ENABLE_BACKUP_VIDEO_IMPORT)"
configured_fallback_capture="$(extract_setting STOCKPILE_ENABLE_CONFIGURED_FALLBACK_CAPTURE)"
legacy_review_presentation="$(extract_setting STOCKPILE_REVIEW_PRESENTATION)"
api_timeout="$(extract_setting STOCKPILE_API_TIMEOUT_SECONDS)"
auth_bearer="$(extract_setting STOCKPILE_API_BEARER_TOKEN)"
auth_header_name="$(extract_setting STOCKPILE_API_AUTH_HEADER_NAME)"
auth_header_value="$(extract_setting STOCKPILE_API_AUTH_HEADER_VALUE)"
processing_poll_interval_ms="$(extract_setting INFOPLIST_KEY_STOCKPILE_PROCESSING_POLL_INTERVAL_MS)"
upload_background_session_id="$(extract_setting INFOPLIST_KEY_STOCKPILE_UPLOAD_BACKGROUND_SESSION_ID)"
camera_usage_description="$(extract_setting INFOPLIST_KEY_NSCameraUsageDescription)"
location_usage_description="$(extract_setting INFOPLIST_KEY_NSLocationWhenInUseUsageDescription)"
photo_library_usage_description="$(extract_setting INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription)"
non_exempt_encryption="$(extract_setting INFOPLIST_KEY_ITSAppUsesNonExemptEncryption)"
debug_information_format="$(extract_setting DEBUG_INFORMATION_FORMAT)"
validate_product="$(extract_setting VALIDATE_PRODUCT)"
copy_phase_strip="$(extract_setting COPY_PHASE_STRIP)"
tracked_demo_setting_hits="$(
  rg -n \
    "STOCKPILE_REVIEW_PRESENTATION[[:space:]]*:|STOCKPILE_USE_MOCK_RESULTS[[:space:]]*[:=][[:space:]]*(YES|yes|true|1)|STOCKPILE_LAUNCH_MODE[[:space:]]*[:=][[:space:]]*(review_presentation|review-presentation|reviewpresentation|presentation|demo|review)" \
    "$PROJECT_SPEC" \
    "$PBXPROJ" || true
)"
tracked_capture_fallback_hits="$(
  rg -n \
    "STOCKPILE_CAPTURE_FILE_(PATH|URL)|INFOPLIST_KEY_STOCKPILE_CAPTURE_FILE_(PATH|URL)|STOCKPILE_ENABLE_BACKUP_VIDEO_IMPORT[[:space:]]*[:=][[:space:]]*(YES|yes|true|1)|STOCKPILE_ENABLE_CONFIGURED_FALLBACK_CAPTURE[[:space:]]*[:=][[:space:]]*(YES|yes|true|1)" \
    "$PROJECT_SPEC" \
    "$PBXPROJ" || true
)"
archive_config="$(
  grep -A 2 "<ArchiveAction" "$SCHEME_FILE" | \
    sed -n 's/.*buildConfiguration = "\([^"]*\)".*/\1/p' | \
    head -n 1
)"

echo "Release build summary:"
echo "  Bundle ID:            ${bundle_id:-<unset>}"
echo "  Development team:     ${team_id:-<unset>}"
echo "  Code sign style:      ${code_sign_style:-<unset>}"
echo "  Marketing version:    ${marketing_version:-<unset>}"
echo "  Build number:         ${build_number:-<unset>}"
echo "  Environment:          ${environment_name:-<unset>}"
echo "  API base URL:         ${api_base_url:-<unset>}"
echo "  Launch mode:          ${launch_mode:-<unset>}"
echo "  Live camera:          ${use_live_camera:-<unset>}"
echo "  Mock results:         ${use_mock_results:-<unset>}"
echo "  Backup import:        ${backup_video_import:-<unset>}"
echo "  Configured fallback:  ${configured_fallback_capture:-<unset>}"
echo "  API timeout seconds:  ${api_timeout:-<unset>}"
echo "  Poll interval ms:     ${processing_poll_interval_ms:-<unset>}"
echo "  Upload session ID:    ${upload_background_session_id:-<unset>}"
echo "  Archive configuration:${archive_config:-<unset>}"
echo

if [[ "$PROJECT_SPEC" -nt "$PBXPROJ" ]]; then
  fail "Generated Xcode project is stale. Run ./ios/generate-project.sh before archiving."
else
  pass "Generated Xcode project is in sync with ios/project.yml."
fi

if [[ -n "$tracked_demo_setting_hits" ]]; then
  fail "Tracked iOS config still bakes in demo or review-presentation defaults. Keep demo mode opt-in via explicit local overrides only."
else
  pass "Tracked iOS config keeps demo and review-presentation defaults out of the build."
fi

if [[ -n "$tracked_capture_fallback_hits" ]]; then
  fail "Tracked iOS config still bakes in file-backed capture fallback settings. Remove capture-file defaults before TestFlight."
else
  pass "Tracked iOS config does not bake in file-backed capture fallback."
fi

if [[ -n "$bundle_id" ]]; then
  pass "Release bundle identifier is set."
else
  fail "Release bundle identifier is empty."
fi

if [[ "$code_sign_style" == "Automatic" ]]; then
  pass "Automatic signing is enabled."
else
  fail "Automatic signing is not enabled."
fi

if [[ -n "$team_id" ]]; then
  pass "Development team is configured."
else
  warn "Apple team is still unset in the repo. Inject STOCKPILE_DEVELOPMENT_TEAM before archiving."
fi

if [[ -n "$marketing_version" && -n "$build_number" ]]; then
  pass "Release version and build number are both set."
else
  fail "Release marketing/build version is incomplete."
fi

if [[ "$build_number" == "1" ]]; then
  warn "Build number is still 1. Choose an intentional external-test build number before upload."
fi

if [[ "$environment_name" == "Staging" ]]; then
  pass "Release environment defaults to Staging."
else
  warn "Release environment is not Staging."
fi

if [[ -z "$api_base_url" ]]; then
  fail "Release API base URL is empty."
elif [[ "$api_base_url" =~ ^https:// ]]; then
  pass "Release API base URL is configured and uses HTTPS."
else
  fail "Release API base URL is not HTTPS."
fi

if [[ "$api_base_url" == *"127.0.0.1"* || "$api_base_url" == *"localhost"* || "$api_base_url" == *"0.0.0.0"* ]]; then
  fail "Release API base URL still points at a local host."
fi

if [[ "$launch_mode" == "operational" ]]; then
  pass "Release launch mode is operational."
else
  fail "Release launch mode is not operational."
fi

if [[ "$use_live_camera" == "YES" ]]; then
  pass "Release defaults to the live camera path."
else
  fail "Release does not default to live camera capture."
fi

if [[ "$use_mock_results" == "NO" ]]; then
  pass "Release does not default to mock results."
else
  fail "Release still enables mock results."
fi

if [[ -n "$legacy_review_presentation" ]]; then
  fail "Legacy review-presentation build settings are still exported in Release. Remove STOCKPILE_REVIEW_PRESENTATION from tracked config."
else
  pass "Release no longer exports a review-presentation build setting."
fi

if [[ "$backup_video_import" == "NO" ]]; then
  pass "Release keeps backup video import disabled by default."
else
  fail "Release still enables backup video import."
fi

if [[ "$configured_fallback_capture" == "NO" ]]; then
  pass "Release keeps configured fallback capture disabled by default."
else
  fail "Release still enables configured fallback capture."
fi

if [[ -n "$upload_background_session_id" ]]; then
  pass "Release upload background session identifier is set."
else
  fail "Release upload background session identifier is empty."
fi

if [[ "$upload_background_session_id" == *".debug"* ]]; then
  fail "Release upload background session identifier still uses a debug naming path."
fi

if [[ "$processing_poll_interval_ms" =~ ^[0-9]+$ ]] && (( processing_poll_interval_ms > 0 )); then
  pass "Release processing poll interval is configured."
else
  fail "Release processing poll interval is missing or invalid."
fi

if [[ -n "$camera_usage_description" ]]; then
  pass "Camera privacy usage text is present."
else
  fail "Camera privacy usage text is missing."
fi

if [[ -n "$location_usage_description" ]]; then
  pass "Location privacy usage text is present."
else
  fail "Location privacy usage text is missing."
fi

if [[ -n "$photo_library_usage_description" ]]; then
  pass "Photo library export usage text is present."
else
  fail "Photo library export usage text is missing."
fi

if [[ "$non_exempt_encryption" == "NO" ]]; then
  pass "Export compliance is explicitly set to non-exempt encryption = NO."
elif [[ -n "$non_exempt_encryption" ]]; then
  warn "Export compliance is not set to NO. Confirm the App Store Connect answer matches the app's crypto usage."
else
  fail "Export compliance Info.plist key is missing."
fi

if [[ "$archive_config" == "Release" ]]; then
  pass "Shared scheme archives with the Release configuration."
else
  fail "ArchiveAction is not set to Release."
fi

if [[ -n "$auth_bearer" && ( -n "$auth_header_name" || -n "$auth_header_value" ) ]]; then
  warn "Both bearer-token and custom-header auth values are present. Confirm the staging API expects both."
elif [[ -n "$auth_bearer" ]]; then
  pass "Release bearer-token auth hook is populated."
elif [[ -n "$auth_header_name" || -n "$auth_header_value" ]]; then
  if [[ -n "$auth_header_name" && -n "$auth_header_value" ]]; then
    pass "Release custom-header auth hook is populated."
  else
    fail "Release custom-header auth is only partially configured."
  fi
else
  warn "Release auth values are blank in the project. Inject bearer or header values before archiving if staging requires auth."
fi

if [[ "$debug_information_format" == "dwarf-with-dsym" ]]; then
  pass "Release debug symbols are configured for archive distribution."
else
  warn "Release debug symbol format is not dwarf-with-dsym."
fi

if [[ "$validate_product" == "YES" ]]; then
  pass "Release product validation is enabled."
else
  warn "Release product validation is not enabled."
fi

if [[ "$copy_phase_strip" == "YES" ]]; then
  pass "Release copy-phase stripping is enabled."
else
  warn "Release copy-phase stripping is not enabled."
fi

if [[ "$status" -eq 0 ]]; then
  echo "No-mock alpha config status: no repo-side blockers found."
else
  echo "No-mock alpha config status: blocking issues found."
fi
echo "This script verifies generated Release configuration only. It does not prove device, network, upload, or backend runtime behavior."
echo

print_section "Configured in Release today" "${pass_items[@]-}"
print_section "Blocking issues before a real TestFlight candidate" "${fail_items[@]-}"
print_section "Archive-time decisions still needed" "${warn_items[@]-}"
print_section "Still required before QPMC external testing" "${manual_items[@]-}"

echo "Summary: ${pass_count} configured, ${warn_count} pending decisions, ${fail_count} blocking issues."

exit "$status"
