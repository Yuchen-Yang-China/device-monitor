#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
build_dir="$project_dir/.build/release"
app_dir="$project_dir/MacMonitor.app"

cd "$project_dir"
if [ -d /Library/Developer/CommandLineTools ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release
mkdir -p "$app_dir/Contents/MacOS"
cp "$build_dir/MacMonitor" "$app_dir/Contents/MacOS/MacMonitor"
cp "$project_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
