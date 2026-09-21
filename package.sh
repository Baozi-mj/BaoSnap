#!/bin/bash
# Package BaoSnap for macOS → dist/*.zip & dist/*.dmg (arm64 + x86_64)
#
# Usage:
#   ./package.sh
#   VERSION=1.1 ./package.sh          # override version in output filenames
#   SIGN_ID="BaoSnap Dev" ./package.sh  # use dev certificate if available
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BaoSnap"
EXE="BaoSnap"
DIST_DIR="dist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
SIGN_ID="${SIGN_ID:-}"

mkdir -p "$DIST_DIR"

codesign_app() {
  local app="$1"
  if [[ -n "$SIGN_ID" ]] && security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    echo "▸ codesign ($SIGN_ID)"
    codesign --force --deep --options runtime --sign "$SIGN_ID" "$app"
  else
    echo "▸ codesign (ad-hoc)"
    codesign --force --deep --sign - "$app"
  fi
}

assemble_app() {
  local binary="$1"
  local app_bundle="$2"

  rm -rf "$app_bundle"
  mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
  cp "$binary" "$app_bundle/Contents/MacOS/$EXE"
  chmod +x "$app_bundle/Contents/MacOS/$EXE"
  cp Resources/Info.plist "$app_bundle/Contents/"
  cp Resources/AppIcon.icns \
     Resources/logo_ui.png Resources/logo_transparent.png \
     Resources/MenuIcon.png Resources/MenuIcon@2x.png Resources/MenuIcon@3x.png \
     Resources/MenuIconDark.png Resources/MenuIconDark@2x.png Resources/MenuIconDark@3x.png \
     "$app_bundle/Contents/Resources/"
  echo -n "APPL????" > "$app_bundle/Contents/PkgInfo"
  codesign_app "$app_bundle"
}

create_zip() {
  local build_dir="$1"
  local zip_path="$2"
  find "$build_dir/$APP_NAME.app" -name '._*' -delete
  rm -f "$zip_path"
  (cd "$build_dir" && zip -r -X "../$zip_path" "$APP_NAME.app")
}

create_dmg() {
  local app_bundle="$1"
  local dmg_stage="$2"
  local dmg_path="$3"

  rm -rf "$dmg_stage"
  mkdir -p "$dmg_stage"
  cp -R "$app_bundle" "$dmg_stage/"
  ln -sf /Applications "$dmg_stage/Applications"
  rm -f "$dmg_path"
  hdiutil create -volname "$APP_NAME" -srcfolder "$dmg_stage" -ov -format UDZO "$dmg_path"
}

package_arch() {
  local arch="$1"
  local triple="${2:-}"
  local build_dir="build/release-${arch}"
  local app_bundle="$build_dir/$APP_NAME.app"
  local zip_name="BaoSnap-v${VERSION}-macOS-${arch}.zip"
  local dmg_name="BaoSnap-v${VERSION}-macOS-${arch}.dmg"
  local dmg_stage="build/dmg-${arch}"
  local binary

  echo ""
  echo "========================================"
  echo "▸ Building release (${arch})"
  echo "========================================"

  if [[ -n "$triple" ]]; then
    swift build -c release --triple "$triple"
    binary="$(swift build -c release --triple "$triple" --show-bin-path)/$EXE"
  else
    swift build -c release
    binary="$(swift build -c release --show-bin-path)/$EXE"
  fi

  [[ -x "$binary" ]] || { echo "error: binary not found: $binary"; exit 1; }
  echo "  binary: $binary ($(file -b "$binary"))"

  echo "▸ Assembling $app_bundle"
  assemble_app "$binary" "$app_bundle"

  echo "▸ Creating zip"
  create_zip "$build_dir" "$DIST_DIR/$zip_name"

  echo "▸ Creating dmg"
  create_dmg "$app_bundle" "$dmg_stage" "$DIST_DIR/$dmg_name"

  ls -lh "$DIST_DIR/$zip_name" "$DIST_DIR/$dmg_name"
}

package_arch arm64
package_arch x86_64 x86_64-apple-macosx

echo ""
echo "✓ Done — packages in $DIST_DIR/:"
ls -lh "$DIST_DIR"/BaoSnap-v"${VERSION}"-macOS-*
