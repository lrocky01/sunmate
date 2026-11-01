#!/bin/bash
# Intentionally independent of Flutter, CocoaPods, signing and Apple accounts.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must point to the runner temporary directory}"
: "${DEVELOPER_DIR:?Select a preinstalled Xcode explicitly}"
: "${WATCH_EXPECTED_XCODE:?Specify the expected Xcode version}"
: "${WATCH_SDK:?Specify a preinstalled watchOS SDK}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log_dir="${RUNNER_TEMP%/}/sunmate-watch-compile-logs"
mkdir -p "$log_dir"
exec > >(tee "$log_dir/check.log") 2>&1

finish() {
  local status=$?
  printf 'Compile check exit status: %s\n' "$status" | tee "$log_dir/status.log"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '### Watch unsigned compile check\n\n'
      printf -- '- Requested Xcode: `%s`\n' "$WATCH_EXPECTED_XCODE"
      printf -- '- Requested SDK: `%s`\n' "$WATCH_SDK"
      printf -- '- Exit status: `%s`\n' "$status"
      printf -- '- Text logs only; no archive, IPA, signing or Apple upload.\n'
      printf -- '- This checks the standalone Watch target, not the iPhone companion or real-device behavior.\n'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}
trap finish EXIT

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 0 ]] || fail 'No extra build arguments are accepted.'
[[ "$RUNNER_TEMP" = /* && "$DEVELOPER_DIR" = /* ]] || fail 'Toolchain and temporary paths must be absolute.'
[[ "$WATCH_EXPECTED_XCODE" =~ ^[0-9]+\.[0-9]+$ ]] || fail 'Invalid explicit Xcode version.'
[[ "$WATCH_SDK" =~ ^watchos[0-9]+\.[0-9]+$ ]] || fail 'Use a versioned watchOS device SDK.'

xcodebuild="$DEVELOPER_DIR/usr/bin/xcodebuild"
[[ -x "$xcodebuild" ]] || fail 'Selected Xcode is not preinstalled; no fallback or download was attempted.'
printf 'Image: %s (%s)\n' "${ImageOS:-unknown}" "${ImageVersion:-unknown}"
printf 'Developer directory: %s\n' "$DEVELOPER_DIR"
version="$("$xcodebuild" -version)"
printf '%s\n' "$version"
actual_version="$(printf '%s\n' "$version" | awk '/^Xcode / { print $2 }')"
[[ "$actual_version" = "$WATCH_EXPECTED_XCODE" ]] || fail 'Preinstalled Xcode version differs from the requested version.'

sdk_version="$("$xcodebuild" -version -sdk "$WATCH_SDK" SDKVersion)"
sdk_path="$("$xcodebuild" -version -sdk "$WATCH_SDK" Path)"
printf 'SDK version: %s\nSDK path: %s\n' "$sdk_version" "$sdk_path"
[[ "$sdk_version" = "${WATCH_SDK#watchos}" && -d "$sdk_path" ]] || fail 'Requested SDK is not preinstalled; no platform download was attempted.'

project="$repo_root/sunmate_app/apple_watch/SunMateWatch.xcodeproj"
[[ -f "$project/project.pbxproj" ]] || fail 'Watch project is missing.'
# This native target currently has no package dependencies. Stop if that changes
# rather than turning this check into an implicit dependency download.
if grep -Eq 'XCRemoteSwiftPackageReference|XCLocalSwiftPackageReference' "$project/project.pbxproj"; then
  fail 'Watch package dependencies require a separate, explicitly reviewed build plan.'
fi
derived="$(mktemp -d "${RUNNER_TEMP%/}/sunmate-watch-derived.XXXXXX")"

"$xcodebuild" \
  -project "$project" \
  -scheme SunMateWatch \
  -configuration Debug \
  -sdk "$WATCH_SDK" \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath "$derived" \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE= \
  PROVISIONING_PROFILE_SPECIFIER= \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build 2>&1 | tee "$log_dir/build.log"
