#!/usr/bin/env bash

set -euo pipefail

usage() {
	printf 'Usage: %s /path/to/sysroot-iOS-TCI-arm64 /empty/output/directory\n' "$(basename "$0")" >&2
}

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

for tool in file find grep lipo nm otool shasum; do
	command -v "$tool" >/dev/null 2>&1 || fail "required macOS tool is missing: $tool"
done

[[ $# -eq 2 ]] || {
	usage
	exit 64
}

SYSROOT="$(cd "$1" && pwd -P)"
FRAMEWORK_ROOT="$SYSROOT/Frameworks"
OUTPUT="$2"
SEED="$FRAMEWORK_ROOT/qemu-aarch64-softmmu.framework"

[[ -d "$SEED" ]] || fail "missing seed framework: $SEED"
if [[ -e "$OUTPUT" ]] && [[ -n "$(find "$OUTPUT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
	fail "output directory is not empty: $OUTPUT"
fi
mkdir -p "$OUTPUT/Frameworks"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ivscode-frameworks.XXXXXX")"
seen="$scratch/seen.txt"
unresolved="$scratch/unresolved.txt"
: > "$seen"
: > "$unresolved"
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

framework_binary() {
	local framework="$1"
	local stem
	stem="$(basename "$framework" .framework)"
	if [[ -f "$framework/$stem" ]]; then
		printf '%s\n' "$framework/$stem"
		return
	fi
	find "$framework" -maxdepth 1 -type f -perm -111 -print | head -n 1
}

collect_framework() {
	local framework="$1"
	local name binary dependency relative dependency_framework
	name="$(basename "$framework")"

	if grep -Fxq "$name" "$seen"; then
		return
	fi
	[[ -d "$framework" ]] || {
		printf '%s\n' "$framework" >> "$unresolved"
		return
	}
	printf '%s\n' "$name" >> "$seen"
	cp -R "$framework" "$OUTPUT/Frameworks/$name"

	binary="$(framework_binary "$framework")"
	[[ -n "$binary" && -f "$binary" ]] || fail "cannot identify Mach-O binary in $framework"
	file "$binary" | grep -q 'Mach-O' || fail "framework entry point is not Mach-O: $binary"
	[[ "$(lipo -archs "$binary")" == "arm64" ]] || fail "framework is not arm64-only: $binary"
	if nm -u "$binary" | grep -Eq '[[:space:]]_hv_[[:alnum:]_]*$'; then
		printf '%s -> forbidden private Hypervisor symbol\n' "$name" >> "$unresolved"
	fi

	while IFS= read -r dependency; do
		[[ -n "$dependency" ]] || continue
		case "$dependency" in
			*/Hypervisor.framework/*)
				printf '%s -> forbidden %s\n' "$name" "$dependency" >> "$unresolved"
				;;
			/System/Library/*|/usr/lib/*)
				continue
				;;
			@rpath/*.framework/*)
				relative="${dependency#@rpath/}"
				dependency_framework="${relative%%.framework/*}.framework"
				collect_framework "$FRAMEWORK_ROOT/$dependency_framework"
				;;
			@loader_path/*|@executable_path/*)
				# UTM's iOS frameworks are flat. Loader-relative paths that stay in
				# the same framework are already copied; anything else is unsafe.
				relative="${dependency#*/}"
				if [[ -e "$framework/$relative" ]]; then
					continue
				fi
				printf '%s -> %s\n' "$name" "$dependency" >> "$unresolved"
				;;
			@rpath/*|/*)
				printf '%s -> %s\n' "$name" "$dependency" >> "$unresolved"
				;;
			*)
				printf '%s -> %s\n' "$name" "$dependency" >> "$unresolved"
				;;
		esac
	done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
}

collect_framework "$SEED"

seed_binary="$(framework_binary "$SEED")"
exported_symbols="$(nm -gjU "$seed_binary")"
for required_export in qemu_init qemu_main_loop qemu_cleanup; do
	grep -Eq "^_?${required_export}$" <<<"$exported_symbols" || \
		fail "QEMU does not export the required launcher symbol: $required_export"
done

if [[ -s "$unresolved" ]]; then
	printf 'Unresolved non-system Mach-O dependencies:\n' >&2
	cat "$unresolved" >&2
	exit 1
fi

LC_ALL=C sort -u "$seen" > "$OUTPUT/frameworks.txt"
if grep -Eiq '(^|[-_.])(spice|gst[a-z0-9]*|gstreamer|virgl|epoxy)([-_.]|$)' "$OUTPUT/frameworks.txt"; then
	printf 'error: disabled display stack leaked into the framework closure\n' >&2
	grep -Ei '(^|[-_.])(spice|gst[a-z0-9]*|gstreamer|virgl|epoxy)([-_.]|$)' "$OUTPUT/frameworks.txt" >&2
	exit 1
fi
runtime_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
cp "$runtime_dir/manifest.json" "$OUTPUT/runtime-manifest.json"
(
	cd "$OUTPUT"
	find Frameworks -type f -print | LC_ALL=C sort | while IFS= read -r path; do
		shasum -a 256 "$path"
	done
	shasum -a 256 frameworks.txt runtime-manifest.json
) > "$OUTPUT/SHA256SUMS"

printf 'Collected %s framework(s) into %s\n' "$(wc -l < "$seen" | tr -d ' ')" "$OUTPUT"
