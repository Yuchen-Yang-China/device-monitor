#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
cd "$project_dir"

print "Checking whitespace and package structure..."
git diff --check
swift package describe --type json >/dev/null

print "Building with warnings treated as errors..."
swift build -c debug -Xswiftc -warnings-as-errors

print "Running tests..."
swift test

print "Checking shell and plist syntax..."
zsh -n Scripts/build-app.sh Scripts/verify.sh
plutil -lint App/Info.plist
[[ -f App/AppIcon.icns ]] || { print -u2 "Missing app icon: App/AppIcon.icns"; exit 1; }

print "Checking build-script path guards..."
expect_build_failure() {
    if ./Scripts/build-app.sh "$@" >/dev/null 2>&1; then
        print -u2 "Expected build-app.sh to reject: $*"
        exit 1
    fi
}
expect_build_failure --output "$project_dir"
expect_build_failure --output /
expect_build_failure --output "$project_dir/not-an-app"
expect_build_failure --output "$project_dir/.app"
./Scripts/build-app.sh --help >/dev/null

if [[ "${DEVICEMONITOR_VERIFY_APP:-0}" == 1 && -d "$project_dir/DeviceMonitor.app" ]]; then
    print "Verifying existing app bundle signature..."
    codesign --verify --deep --strict "$project_dir/DeviceMonitor.app"
fi

print "All local verification checks passed."
