#!/usr/bin/env zsh
# scripts/package-local.sh
#
# Builds a Release .app and zips it to dist/Claude-Usage-<version>.zip
# No signing or notarization — for local sharing only (Gatekeeper will warn).
#
# Usage:
#   ./scripts/package-local.sh
#
# Output:
#   dist/Claude-Usage-<version>.zip

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── Config ──────────────────────────────────────────────────────────────────

PROJECT="Claude Usage.xcodeproj"
SCHEME="Claude Usage"
BUILD_DIR="$REPO_ROOT/.build-local"
DIST_DIR="$REPO_ROOT/dist"

# Read version from project file
VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT/project.pbxproj" \
  | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | xargs)
ZIP_NAME="Claude-Usage-${VERSION}-local.zip"

# ── Build ────────────────────────────────────────────────────────────────────

echo "→ Building Release (unsigned)…"
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "^(error:|warning: |BUILD )" | grep -v "warning: " || true

APP_PATH="$BUILD_DIR/Build/Products/Release/Claude Usage.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "✗ Build failed — app bundle not found at: $APP_PATH"
  exit 1
fi

echo "✓ Build succeeded"

# ── Package ──────────────────────────────────────────────────────────────────

mkdir -p "$DIST_DIR"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

echo "→ Creating $ZIP_NAME…"
# ditto preserves resource forks, symlinks, and extended attributes
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "✓ Done: dist/$ZIP_NAME"
echo "  Size: $(du -sh "$ZIP_PATH" | cut -f1)"

# Open dist/ in Finder
open "$DIST_DIR"
