#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
preview_dir="$project_dir/.codex/native-preview"
build_dir="$preview_dir/build"
app_dir="$preview_dir/NotchDay.app"
module_cache="$preview_dir/module-cache"

mkdir -p "$preview_dir" "$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"

swift_args=(
    --package-path "$project_dir" --scratch-path "$build_dir"
    --cache-path "$preview_dir/swiftpm-cache" --config-path "$preview_dir/swiftpm-config"
    --security-path "$preview_dir/swiftpm-security" --manifest-cache local
    -c release -debug-info-format none
)
if [[ "${NOTCHDAY_MANAGED_BUILD:-0}" == 1 ]]; then
    swift_args+=(--disable-sandbox)
fi
swift build "${swift_args[@]}"
binary_dir="$(swift build "${swift_args[@]}" --show-bin-path)"

install -d "$app_dir/Contents/MacOS"
install -m 644 "$project_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
install -m 755 "$binary_dir/NotchDay" "$app_dir/Contents/MacOS/NotchDay"
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
