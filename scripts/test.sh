#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="${REMOTE_MIC_SELF_TEST_OUTPUT:-$ROOT/.build/self-test/RemoteMicSelfTest}"
TEST_SCRATCH_PATH="${REMOTE_MIC_TEST_SCRATCH_PATH:-}"
TEST_CACHE_PATH="${REMOTE_MIC_TEST_CACHE_PATH:-}"
SKIP_SWIFT_PACKAGE_BUILD="${SKIP_SWIFT_PACKAGE_BUILD:-0}"

case "$SKIP_SWIFT_PACKAGE_BUILD" in
  0|1) ;;
  *) print -u2 "SKIP_SWIFT_PACKAGE_BUILD must be 0 or 1"; exit 1 ;;
esac

mkdir -p "${OUTPUT:h}"
xcrun swiftc \
  "$ROOT/Sources/RemoteMic/ATVVAudioDiagnostics.swift" \
  "$ROOT/Sources/RemoteMic/ATVVProtocol.swift" \
  "$ROOT/Sources/RemoteMic/SystemAudioLifecycle.swift" \
  "$ROOT/Sources/RemoteMic/BluetoothLifecycle.swift" \
  "$ROOT/Sources/RemoteMic/RemoteButtons.swift" \
  "$ROOT/Sources/RemoteMic/ScrollRegionTarget.swift" \
  "$ROOT/Sources/RemoteMic/ButtonBindingConfiguration.swift" \
  "$ROOT/Sources/RemoteMic/KeyboardShortcutPicker.swift" \
  "$ROOT/Sources/RemoteMic/RemoteDeviceProfile.swift" \
  "$ROOT/Sources/RemoteMic/RemoteDeviceIdentity.swift" \
  "$ROOT/Sources/RemoteMic/RemoteButtonInteractionSettings.swift" \
  "$ROOT/Sources/RemoteMic/HIDRemoteScheduler.swift" \
  "$ROOT/Sources/RemoteMic/RemoteDeviceNamePolicy.swift" \
  "$ROOT/Sources/RemoteMic/FirstUseDiagnostics.swift" \
  "$ROOT/Sources/RemoteMic/OnboardingFlow.swift" \
  "$ROOT/Sources/RemoteMic/VoiceKeyMode.swift" \
  "$ROOT/Sources/RemoteMic/AppIconController.swift" \
  "$ROOT/Sources/RemoteMic/RemoteButtonGestureRecognizer.swift" \
  "$ROOT/Sources/RemoteMic/RemoteButtonGestureLearning.swift" \
  "$ROOT/Sources/RemoteMic/AppSettings.swift" \
  "$ROOT/Sources/RemoteMic/VirtualAudioLevelPolicy.swift" \
  "$ROOT/Sources/RemoteMic/LocalUsageLedger.swift" \
  "$ROOT/Sources/RemoteMic/OfflineRuntimePolicy.swift" \
  "$ROOT/Sources/RemoteMic/MacConfigurationBackup.swift" \
  "$ROOT/Sources/RemoteMic/MembershipFeatureTypes.swift" \
  "$ROOT/Sources/RemoteMic/ChromecastFeatureIntegration.swift" \
  "$ROOT/Sources/RemoteMic/ChromecastRemoteIdentity.swift" \
  "$ROOT/Sources/RemoteMic/HIDReportRunLoop.swift" \
  "$ROOT/Sources/RemoteMic/ChromecastHIDControlSource.swift" \
  "$ROOT/Sources/RemoteMic/PublicChromecastBluetoothBridge.swift" \
  "$ROOT/Sources/RemoteMic/AppLinks.swift" \
  "$ROOT/Sources/RemoteMic/Localization.swift" \
  "$ROOT/Sources/RemoteMic/VoiceFunctionKeyLatch.swift" \
  "$ROOT/Sources/RemoteMic/AXSelfTargetPolicy.swift" \
  "$ROOT/Sources/RemoteMic/VoiceInputDestinationCoordinator.swift" \
  "$ROOT/Sources/RemoteMic/VoiceFnTapSessionController.swift" \
  "$ROOT/Sources/RemoteMic/RemoteVoiceFunctionMapper.swift" \
  "$ROOT/Sources/RemoteMic/PublicDiagnosticEvent.swift" \
  "$ROOT/Sources/RemoteMic/PublicDiagnosticEventStore.swift" \
  "$ROOT/Sources/RemoteMic/DiagnosticLogEnvelope.swift" \
  "$ROOT/Sources/RemoteMic/AppLogger.swift" \
  "$ROOT/Sources/RemoteMic/TestTone.swift" \
  "$ROOT/Tests/SelfTest/main.swift" \
  -o "$OUTPUT"
"$OUTPUT"

if [[ "$SKIP_SWIFT_PACKAGE_BUILD" == "0" ]]; then
  swift_build_arguments=(--disable-keychain)
  if [[ -n "$TEST_SCRATCH_PATH" ]]; then
    swift_build_arguments+=(--scratch-path "$TEST_SCRATCH_PATH")
  fi
  if [[ -n "$TEST_CACHE_PATH" ]]; then
    swift_build_arguments+=(--cache-path "$TEST_CACHE_PATH")
  fi
  xcrun swift build "${swift_build_arguments[@]}"
else
  print "SWIFT PACKAGE BUILD SKIPPED: already completed by the current CI job"
fi
