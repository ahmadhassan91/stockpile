#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_SPEC="$ROOT_DIR/project.yml"
APP_DIR="$ROOT_DIR/StockpileCaptureApp"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

if [[ ! -f "$PROJECT_SPEC" ]]; then
  echo "Missing XcodeGen spec at $PROJECT_SPEC" >&2
  exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app source directory at $APP_DIR" >&2
  exit 1
fi

cd "$ROOT_DIR"
xcodegen generate

echo "Generated StockpileCaptureApp.xcodeproj"
echo "Debug and Release both point to the HTTPS mobile API path by default."
echo "Override STOCKPILE_DEVELOPMENT_TEAM / STOCKPILE_BUILD_NUMBER / STOCKPILE_MARKETING_VERSION at archive time as needed."
