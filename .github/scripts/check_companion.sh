#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?Runner temporary directory required}"
: "${DEVELOPER_DIR:?Explicit preinstalled Xcode required}"
: "${WATCH_EXPECTED_XCODE:?Explicit Xcode version required}"
: "${WATCH_SDK:?Explicit Watch SDK required}"
: "${IPHONE_SDK:?Explicit iPhone SDK required}"
[[ $# -eq 1 && "$1" =~ ^(preflight|prepare|build)$ ]] || { echo 'Expected preflight, prepare or build'; exit 1; }
phase="$1"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log_dir="${RUNNER_TEMP%/}/sunmate-companion-compile-logs"
mkdir -p "$log_dir"
exec > >(tee "$log_dir/$phase.log") 2>&1
trap 'status=$?; printf "Phase %s exit status: %s\n" "$phase" "$status"' EXIT
xcodebuild="$DEVELOPER_DIR/usr/bin/xcodebuild"
[[ -x "$xcodebuild" ]] || { echo 'Selected Xcode is absent; no download or fallback'; exit 1; }

case "$phase" in
  preflight)
    "$xcodebuild" -version
    actual="$("$xcodebuild" -version | awk '/^Xcode / {print $2}')"
    [[ "$actual" = "$WATCH_EXPECTED_XCODE" ]]
    for sdk in "$IPHONE_SDK" "$WATCH_SDK"; do
      version="$("$xcodebuild" -version -sdk "$sdk" SDKVersion)"
      path="$("$xcodebuild" -version -sdk "$sdk" Path)"
      [[ "$sdk" = "iphoneos$version" || "$sdk" = "watchos$version" ]]
      [[ -d "$path" ]]
      printf 'Preinstalled SDK: %s (%s)\n' "$sdk" "$path"
    done
    ;;
  prepare)
    cd "$repo_root/sunmate_app"
    flutter --suppress-analytics --no-version-check --version
    flutter config --no-enable-swift-package-manager
    flutter precache --ios
    flutter pub get --enforce-lockfile
    flutter analyze --no-pub --no-fatal-infos
    flutter test --no-pub --reporter expanded
    # Configuration/pod setup only: the actual compile is the next phase.
    flutter build ios --debug --config-only --no-codesign --no-pub
    git diff --exit-code -- pubspec.yaml pubspec.lock
    ;;
  build)
    cd "$repo_root/sunmate_app"
    derived="$(mktemp -d "${RUNNER_TEMP%/}/sunmate-companion-derived.XXXXXX")"
    # Destination chooses iPhoneOS for Runner and WatchOS for its dependency.
    # A global -sdk iphoneos would incorrectly override the Watch target SDK.
    version="$(awk '/^version:/ {print $2}' pubspec.yaml)"
    "$xcodebuild" \
      -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
      -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
      -disableAutomaticPackageResolution -skipPackageUpdates \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
      DEVELOPMENT_TEAM= PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER= \
      "MARKETING_VERSION=${version%+*}" "CURRENT_PROJECT_VERSION=${version#*+}" \
      COMPILER_INDEX_STORE_ENABLE=NO build
    python3 "$repo_root/.github/scripts/verify_companion.py" \
      "$derived/Build/Products/Debug-iphoneos/Runner.app" \
      --iphone-sdk "$IPHONE_SDK" --watch-sdk "$WATCH_SDK" \
      | tee "$log_dir/verification.log"
    ;;
esac
