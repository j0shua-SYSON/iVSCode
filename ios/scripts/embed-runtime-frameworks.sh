#!/usr/bin/env bash

set -euo pipefail

[[ "${PLATFORM_NAME:-}" == "iphoneos" ]] || exit 0

runtime_root="$SRCROOT/iVSCode/Generated/Runtime"
source_root="$runtime_root/Frameworks"
manifest="$runtime_root/frameworks.txt"
destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"

if [[ ! -f "$manifest" ]]; then
	if [[ "${IVSCODE_REQUIRE_RUNTIME:-0}" == "1" ]]; then
		printf 'error: the required no-JIT framework manifest is missing: %s\n' "$manifest" >&2
		exit 1
	fi
	exit 0
fi

[[ -d "$source_root" ]] || {
	printf 'error: the runtime framework directory is missing: %s\n' "$source_root" >&2
	exit 1
}
source_root="$(cd "$source_root" && pwd -P)"

mkdir -p "$destination"
expected=0
while IFS= read -r framework; do
	[[ -n "$framework" ]] || continue
	[[ "$framework" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.framework$ && "$framework" != *..* ]] || {
		printf 'error: unsafe runtime framework manifest entry: %s\n' "$framework" >&2
		exit 1
	}
	[[ "$(grep -Fxc "$framework" "$manifest")" == "1" ]] || {
		printf 'error: duplicate runtime framework manifest entry: %s\n' "$framework" >&2
		exit 1
	}
	expected=$((expected + 1))
	source="$source_root/$framework"
	[[ -d "$source" ]] || {
		printf 'error: runtime closure member is missing: %s\n' "$framework" >&2
		exit 1
	}
	resolved_source="$(cd "$source" && pwd -P)"
	[[ "$resolved_source" == "$source_root/$framework" ]] || {
		printf 'error: runtime framework escapes the reviewed closure: %s\n' "$framework" >&2
		exit 1
	}
	if /usr/bin/codesign --display --entitlements :- --xml "$resolved_source" 2>/dev/null | /usr/bin/grep -q '<key>'; then
		printf 'error: runtime framework carries nested entitlements: %s\n' "$framework" >&2
		exit 1
	fi
	rm -rf "$destination/$framework"
	/usr/bin/ditto "$source" "$destination/$framework"
	if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
		/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
			--preserve-metadata=identifier "$destination/$framework"
		/usr/bin/codesign --verify --strict "$destination/$framework"
	fi
done < "$manifest"

[[ "$expected" -gt 0 ]] || {
	printf 'error: the runtime framework manifest is empty\n' >&2
	exit 1
}

actual="$(find "$destination" -mindepth 1 -maxdepth 1 -type d -name '*.framework' | wc -l | tr -d ' ')"
[[ "$actual" == "$expected" ]] || {
	printf 'error: embedded %s runtime frameworks, expected %s\n' "$actual" "$expected" >&2
	exit 1
}
