#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"

configuration=release
architecture=native
app_dir="$project_dir/DeviceMonitor.app"
signing_identity="${DEVICEMONITOR_SIGNING_IDENTITY:-}"

usage() {
    cat <<'EOF'
Usage: ./Scripts/build-app.sh [options]

Options:
  --configuration <debug|release>  Build configuration (default: release)
  --arch <native|arm64|x86_64|universal>
                                   Output architecture (default: native)
  --output <path>                  App bundle path (default: ./DeviceMonitor.app)
  --identity <identity>            codesign identity; defaults to
                                   DEVICEMONITOR_SIGNING_IDENTITY when set
  -h, --help                       Show this help

Without a signing identity the bundle is signed ad hoc. This is suitable for
local development and verification, but not for distribution through
Gatekeeper. Set DEVICEMONITOR_SIGNING_IDENTITY to a Developer ID identity for a
release build.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --configuration)
            [[ $# -ge 2 ]] || { print -u2 "Missing value for --configuration"; exit 2; }
            configuration="$2"
            shift 2
            ;;
        --arch)
            [[ $# -ge 2 ]] || { print -u2 "Missing value for --arch"; exit 2; }
            architecture="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { print -u2 "Missing value for --output"; exit 2; }
            app_dir="$2"
            shift 2
            ;;
        --identity)
            [[ $# -ge 2 ]] || { print -u2 "Missing value for --identity"; exit 2; }
            signing_identity="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

case "$configuration" in
    debug|release) ;;
    *) print -u2 "Invalid configuration: $configuration"; exit 2 ;;
esac

case "$architecture" in
    native|arm64|x86_64|universal) ;;
    *) print -u2 "Invalid architecture: $architecture"; exit 2 ;;
esac

if [[ "$app_dir" != /* ]]; then
    app_dir="$project_dir/$app_dir"
fi
if [[ -z "$app_dir" ]]; then
    print -u2 "Refusing an empty app bundle path"
    exit 2
fi
requested_app_dir="$app_dir"
check_path_components() {
    local path="$1"
    local current="/"
    local component
    local -a components
    components=("${(@s:/:)path}")
    for component in "${components[@]}"; do
        [[ -z "$component" ]] && continue
        if [[ "$component" == "." || "$component" == ".." ]]; then
            print -u2 "Refusing an output path with dot components: $path"
            return 1
        fi
        current="${current%/}/$component"
        # macOS exposes /tmp as a symlink to /private/tmp; this one system
        # alias is harmless and is explicitly supported by the documentation.
        if [[ -L "$current" && "$current" != "/tmp" ]]; then
            print -u2 "Refusing an output path redirected by a parent symlink: $path"
            return 1
        fi
    done
}
check_path_components "$requested_app_dir" || exit 2
resolved_app_dir="${app_dir:A}"
app_dir="$resolved_app_dir"
app_name="${app_dir:t}"
parent_dir="${app_dir:h}"
if [[ "$app_dir" == "/" || "$app_dir" == "$project_dir" ]]; then
    print -u2 "Refusing a broad app bundle path: $app_dir"
    exit 2
fi
if [[ "$app_name" != *.app || "$app_name" == ".app" || "$parent_dir" == "/" ]]; then
    print -u2 "Output must be a named .app bundle below the filesystem root: $app_dir"
    exit 2
fi
if [[ -e "$app_dir" && ! -d "$app_dir" ]]; then
    print -u2 "Output path is not a directory: $app_dir"
    exit 2
fi

cd "$project_dir"
if [[ "$architecture" != universal && -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

build_args=(-c "$configuration")
expected_architectures=()
case "$architecture" in
    native)
        expected_architectures=("$(uname -m)")
        ;;
    arm64)
        build_args+=(--arch arm64)
        expected_architectures=(arm64)
        ;;
    x86_64)
        build_args+=(--arch x86_64)
        expected_architectures=(x86_64)
        ;;
    universal)
        build_args+=(--arch arm64 --arch x86_64)
        expected_architectures=(arm64 x86_64)
        ;;
esac

print "Building DeviceMonitor ($configuration, $architecture)..."
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
binary="$bin_dir/DeviceMonitor"
[[ -x "$binary" ]] || { print -u2 "Build did not produce executable: $binary"; exit 1; }

actual_architectures="$(lipo -archs "$binary" 2>/dev/null || true)"
[[ -n "$actual_architectures" ]] || { print -u2 "Unable to inspect executable architectures"; exit 1; }
for expected in "${expected_architectures[@]}"; do
    [[ " $actual_architectures " == *" $expected "* ]] || {
        print -u2 "Expected architecture $expected, got: $actual_architectures"
        exit 1
    }
done
if [[ "$architecture" != universal ]]; then
    actual_count="$(wc -w <<< "$actual_architectures" | tr -d ' ')"
    [[ "$actual_count" == 1 ]] || {
        print -u2 "Expected a single architecture for $architecture, got: $actual_architectures"
        exit 1
    }
fi

# Start from a clean Contents directory so stale signatures/resources cannot
# survive a rebuild. The bundle path was validated above and symlink targets are
# rejected; the app's parent directory is never removed.
if [[ -L "$app_dir/Contents" ]]; then
    print -u2 "Refusing a symlink Contents directory: $app_dir/Contents"
    exit 2
fi
if [[ -e "$app_dir/Contents" && ! -d "$app_dir/Contents" ]]; then
    print -u2 "Existing Contents path is not a directory: $app_dir/Contents"
    exit 2
fi
icon_file="$project_dir/App/AppIcon.icns"
[[ -f "$icon_file" ]] || { print -u2 "Missing app icon: $icon_file"; exit 1; }
rm -rf "$app_dir/Contents"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary" "$app_dir/Contents/MacOS/DeviceMonitor"
cp "$project_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$icon_file" "$app_dir/Contents/Resources/AppIcon.icns"

if [[ -n "$signing_identity" ]]; then
    print "Signing with identity: $signing_identity"
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_dir/Contents/MacOS/DeviceMonitor"
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_dir"
else
    print "Signing ad hoc (set DEVICEMONITOR_SIGNING_IDENTITY for distribution)"
    codesign --force --timestamp=none --sign - "$app_dir/Contents/MacOS/DeviceMonitor"
    codesign --force --timestamp=none --sign - "$app_dir"
fi

codesign --verify --deep --strict --verbose=2 "$app_dir"
print "Created and verified: $app_dir"
if [[ -z "$signing_identity" ]]; then
    print "Gatekeeper assessment is intentionally not run for an ad-hoc signature."
else
    spctl --assess --type execute --verbose=2 "$app_dir"
fi
