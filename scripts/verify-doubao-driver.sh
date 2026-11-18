#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/release-variant.sh"
DRIVER="${1:-$RELEASE_OUTPUT_DIR/MiRemoteV2ch.driver}"
NAMING_VARIANT="${2:-brand}"
PLIST="$DRIVER/Contents/Info.plist"
BINARY="$DRIVER/Contents/MacOS/MiRemoteV2ch"
EXPECTED_DEVELOPER_TEAM_ID="${EXPECTED_DEVELOPER_TEAM_ID:-}"
REQUIRE_DEVELOPER_ID_SIGNING="${REQUIRE_DEVELOPER_ID_SIGNING:-0}"

case "$REQUIRE_DEVELOPER_ID_SIGNING" in
  0|1) ;;
  *) print -u2 "REQUIRE_DEVELOPER_ID_SIGNING must be 0 or 1"; exit 1 ;;
esac
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" && -z "$EXPECTED_DEVELOPER_TEAM_ID" ]]; then
  print -u2 "EXPECTED_DEVELOPER_TEAM_ID is required for Developer ID verification"
  exit 1
fi

test -d "$DRIVER"
test -f "$PLIST"
test -x "$BINARY"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = "com.hd838a.MiRemoteV2ch"
test "$(/usr/bin/plutil -extract CFBundleName raw -o - "$PLIST")" = "MiRemoteV2ch"
/usr/bin/codesign --verify --deep --strict "$DRIVER"
if [[ "$REQUIRE_DEVELOPER_ID_SIGNING" == "1" ]]; then
  SIGNATURE_DETAILS="$(/usr/bin/codesign -dvvv "$DRIVER" 2>&1)"
  print -r -- "$SIGNATURE_DETAILS" | /usr/bin/grep -qE '^Authority=Developer ID Application:'
  print -r -- "$SIGNATURE_DETAILS" | /usr/bin/grep -qE "^TeamIdentifier=$EXPECTED_DEVELOPER_TEAM_ID$"
  print -r -- "$SIGNATURE_DETAILS" | /usr/bin/grep -qE '^CodeDirectory .*flags=.*runtime'
fi
ARCHS="$(/usr/bin/lipo -archs "$BINARY")"
test "$ARCHS" = "$RELEASE_ARCH"
/usr/bin/xcrun vtool -show-build "$BINARY" | /usr/bin/grep -Fq "minos $RELEASE_MIN_SYSTEM_VERSION"
case "$NAMING_VARIANT" in
  brand) DEVICE_NAME="SayAll" ;;
  legacy) DEVICE_NAME="MiRemoteV %ich" ;;
  *) print -u2 "unknown driver naming variant"; exit 1 ;;
esac
test "$(/usr/bin/plutil -extract SayAllNamingVariant raw -o - "$PLIST")" = "$NAMING_VARIANT"
/usr/bin/strings "$BINARY" | /usr/bin/grep -Fxq "$DEVICE_NAME"
/usr/bin/strings "$BINARY" | /usr/bin/grep -Fxq 'MiRemoteV%ich_UID'
/usr/bin/strings "$BINARY" | /usr/bin/grep -Fxq 'MiRemoteV%ich_ModelUID'
/usr/bin/strings "$BINARY" | /usr/bin/grep -Fxq 'MiRemoteV%ich_2_UID'

print "DOUBAO DRIVER VERIFY PASS: $DRIVER"
print "RELEASE VARIANT: $RELEASE_VARIANT"
