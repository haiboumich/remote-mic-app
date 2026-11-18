#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
REQUESTED_VARIANT="${1:-native}"
WORK_ROOT=""

cleanup() {
  case "$WORK_ROOT" in
    /private/tmp/sayall-offline-build.*)
      /bin/rm -rf -- "$WORK_ROOT"
      ;;
    "") ;;
    *) print -u2 "refusing to clean unexpected offline build path: $WORK_ROOT" ;;
  esac
}
trap cleanup EXIT

usage() {
  print -u2 "usage: ${0:t} [native|apple-silicon|intel|all]"
}

case "$REQUESTED_VARIANT" in
  native|apple-silicon|intel|all) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
  print -u2 "Full Xcode is required. Install and select it as described in BUILD_PREREQUISITES.md."
  exit 1
fi

if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]]; then
  print -u2 "Offline DMGs must be built from a clean checkout so their source identity is reproducible."
  exit 1
fi

SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Resources/Info.plist")"
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$ROOT/Resources/Info.plist")"
WORK_ROOT="$(/usr/bin/mktemp -d /private/tmp/sayall-offline-build.XXXXXX)"

unset SAYALL_AI_PACKAGE_PATH SAYALL_COMBINATION_ACTIONS_PATH \
  SAYALL_BUTTON_PROFILES_PACKAGE_PATH SAYALL_MAC_REMOTE_PACKAGE_PATH \
  SAYALL_PRIVATE_ARTIFACT_PACKAGE_PATH SAYALL_SIRI_REMOTE_PACKAGE_PATH \
  SAYALL_CHROMECAST_PACKAGE_PATH SAYALL_PRIVATE_PLATFORM_PACKAGE_PATH \
  SAYALL_PRIVATE_SOURCE_ROOT SAYALL_LOCAL_PRIVATE_SOURCE_COMMIT \
  SAYALL_PRIVATE_PLATFORM_VERSION SAYALL_ENABLE_PRIVATE_SWIFTPM \
  SAYALL_PRIVATE_ARTIFACTS_SOURCE \
  SAYALL_ENABLE_SIRI_REMOTE SAYALL_ENABLE_CHROMECAST \
  SAYALL_MEMBERSHIP_PACKAGE_PATH SAYALL_MEMBERSHIP_ADAPTER_PACKAGE_PATH \
  SAYALL_DIAGNOSTIC_PUBLIC_KEY_BASE64 SAYALL_CLIENT_PROOF_KEY \
  SAYALL_SCREENSHOT_PROFILE_SEED SAYALL_OPUS_LIBRARY SAYALL_OPUS_CACHE_ROOT \
  REMOTE_MIC_SENTRY_DSN REMOTE_MIC_HARDWARE_SIMULATION_PATH \
  REMOTE_MIC_APP_DESTINATION EXPECTED_DEVELOPER_TEAM_ID
export SAYALL_PRIVATE_PLATFORM_MODE=public
export SAYALL_BUILD_CHANNEL=public
export CODE_SIGN_IDENTITY=-
export INSTALLER_SIGNING_IDENTITY=-
export CONFIGURATION=release
export RELEASE_STAGE_TIMEOUTS=0
export REQUIRE_SIRI_REMOTE_SIGNING=0
export REQUIRE_DEVELOPER_ID_SIGNING=0
export REQUIRE_NOTARIZATION=0
export REQUIRE_WEB_REMOTE_CONFIGURATION=0
export REQUIRE_EARLY_ACCESS_CONFIGURATION=0
export REQUIRE_SAYALL_AI_PACKAGE=0
export REQUIRE_SAYALL_COMBINATION_ACTIONS=0
export REQUIRE_SAYALL_BUTTON_PROFILES=0
export REQUIRE_SAYALL_MAC_REMOTE_PACKAGE=0
export REQUIRE_SAYALL_PRIVATE_ARTIFACT_PACKAGE=0
export REQUIRE_SAYALL_CHROMECAST=0
export REQUIRE_SAYALL_BUTTON_PROFILES_TEST_ACCESS=0
export REQUIRE_DIAGNOSTIC_PUBLIC_KEY=0
export REQUIRE_DIAGNOSTIC_SERVICE=0
export REQUIRE_RELEASE_BUILD_CHANNEL=0
export REQUIRE_CLIENT_PROOF_KEY=0
export SAYALL_TEST_BUTTON_PROFILES_FREE=0

REMOTE_MIC_SELF_TEST_OUTPUT="$WORK_ROOT/self-test/RemoteMicSelfTest" \
REMOTE_MIC_TEST_SCRATCH_PATH="$WORK_ROOT/self-test-swiftpm" \
REMOTE_MIC_TEST_CACHE_PATH="$WORK_ROOT/self-test-cache" \
SKIP_SWIFT_PACKAGE_BUILD=0 \
  "$ROOT/scripts/test.sh"
xcrun swift test \
  --disable-keychain \
  --scratch-path "$WORK_ROOT/swift-tests" \
  --cache-path "$WORK_ROOT/swift-test-cache"

if [[ "$REQUESTED_VARIANT" == "native" ]]; then
  if [[ "$(/usr/bin/uname -m)" == "arm64" ]]; then
    VARIANTS=(apple-silicon)
  else
    VARIANTS=(intel)
  fi
elif [[ "$REQUESTED_VARIANT" == "all" ]]; then
  VARIANTS=(apple-silicon intel)
else
  VARIANTS=("$REQUESTED_VARIANT")
fi

for variant in "${VARIANTS[@]}"; do
  (
    export RELEASE_VARIANT="$variant"
    export BUILD_COMPONENTS=1
    export REMOTE_MIC_BUILD_SCRATCH_PATH="$WORK_ROOT/$variant/app-swiftpm"
    export REMOTE_MIC_BUILD_CACHE_PATH="$WORK_ROOT/$variant/app-cache"

    "$ROOT/scripts/build-dmg.sh"
    "$ROOT/scripts/verify-dmg.sh"

    source "$ROOT/scripts/release-variant.sh"
    DMG="$RELEASE_OUTPUT_DIR/SayAll-$VERSION-$BUILD$RELEASE_ASSET_SUFFIX.dmg"
    "$ROOT/scripts/verify-release-asset-source.sh" \
      --asset "$DMG" \
      --expected-commit "$SOURCE_COMMIT"
    print "OFFLINE DMG READY: $DMG"
  )
done
