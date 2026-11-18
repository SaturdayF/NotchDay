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

icon_dir="$build_dir/app-icon"
catalog="$icon_dir/Assets.xcassets"
icon_set="$catalog/AppIcon.appiconset"
compiled_icons="$icon_dir/compiled"
mkdir -p "$icon_set" "$compiled_icons"
printf '%s\n' '{"info":{"author":"xcode","version":1}}' > "$catalog/Contents.json"
sips -s format png "$project_dir/App/NotchDay.icns" --out "$icon_dir/source.png" >/dev/null
{
    printf '{"images":['
    separator=""
    for size in 16 32 128 256 512; do
        for scale in 1 2; do
            pixels=$((size * scale))
            name="AppIcon-${size}@${scale}x.png"
            sips -z "$pixels" "$pixels" "$icon_dir/source.png" --out "$icon_set/$name" >/dev/null
            printf '%s{"filename":"%s","idiom":"mac","size":"%sx%s","scale":"%sx"}' \
                "$separator" "$name" "$size" "$size" "$scale"
            separator=","
        done
    done
    printf '],"info":{"author":"xcode","version":1}}\n'
} > "$icon_set/Contents.json"
if ! xcrun actool "$catalog" --compile "$compiled_icons" --platform macosx --minimum-deployment-target 26.0 \
    --target-device mac --app-icon AppIcon --output-partial-info-plist "$icon_dir/icons.plist" \
    > "$icon_dir/actool.log" 2>&1; then
    cat "$icon_dir/actool.log"
    exit 1
fi

install -d "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
install -m 644 "$project_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
install -m 644 "$compiled_icons/AppIcon.icns" "$compiled_icons/Assets.car" "$app_dir/Contents/Resources/"
rm -f "$app_dir/Contents/Resources/NotchDay.icns"
install -m 755 "$binary_dir/NotchDay" "$app_dir/Contents/MacOS/NotchDay"
codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
