#!/usr/bin/env bash

set -euo pipefail

source_icon="$SRCROOT/../resources/server/code-512.png"
generator="$SRCROOT/scripts/generate-app-icon.swift"
output="$SRCROOT/iVSCode/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
scratch_root="${DERIVED_FILE_DIR:-$SRCROOT/.build/icon}"
temporary="$scratch_root/AppIcon-1024.png"
module_cache="$SRCROOT/.build/swift-module-cache"

[[ -f "$source_icon" && -f "$generator" ]] || {
	printf 'error: the reviewed iVSCode icon inputs are missing\n' >&2
	exit 1
}
mkdir -p "$scratch_root" "$module_cache" "$(dirname "$output")"

SWIFT_MODULECACHE_PATH="$module_cache" \
CLANG_MODULE_CACHE_PATH="$module_cache" \
	xcrun --sdk macosx swift -module-cache-path "$module_cache" \
		"$generator" "$source_icon" "$temporary"

width="$(sips -g pixelWidth "$temporary" | awk '/pixelWidth:/ { print $2 }')"
height="$(sips -g pixelHeight "$temporary" | awk '/pixelHeight:/ { print $2 }')"
alpha="$(sips -g hasAlpha "$temporary" | awk '/hasAlpha:/ { print $2 }')"
[[ "$width" == "1024" && "$height" == "1024" && "$alpha" == "no" ]] || {
	printf 'error: generated app icon must be an opaque 1024x1024 PNG\n' >&2
	exit 1
}

if [[ ! -f "$output" ]] || ! cmp -s "$temporary" "$output"; then
	/usr/bin/ditto "$temporary" "$output"
fi
