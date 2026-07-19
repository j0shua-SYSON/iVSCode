#!/usr/bin/env bash

set -euo pipefail

usage() {
	printf 'Usage: %s --engine /path/to/engine --guest /path/to/guest.tar.zst\n' "$(basename "$0")" >&2
}

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

engine=""
guest=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--engine) engine="$2"; shift 2 ;;
		--guest) guest="$2"; shift 2 ;;
		*) usage; exit 64 ;;
	esac
done

[[ -d "$engine" && -f "$guest" ]] || {
	usage
	exit 64
}
for tool in cmp ditto shasum tar zstd; do
	command -v "$tool" >/dev/null 2>&1 || fail "required staging tool is missing: $tool"
done

engine="$(cd "$engine" && pwd -P)"
guest="$(cd "$(dirname "$guest")" && pwd -P)/$(basename "$guest")"
ios_root="$(cd "$(dirname "$0")/.." && pwd -P)"
generated_root="$ios_root/iVSCode/Generated"
destination="$generated_root/Runtime"
[[ "$destination" == "$ios_root/iVSCode/Generated/Runtime" ]] || fail "unsafe runtime destination"

(
	cd "$engine"
	shasum -a 256 --check SHA256SUMS
)

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ivscode-stage-runtime.XXXXXX")"
staging="$(mktemp -d "$generated_root/.Runtime.staging.XXXXXX")"
backup="$generated_root/.Runtime.backup.$$"
[[ "$staging" == "$generated_root"/.Runtime.staging.* ]] || fail "unsafe staging destination"
[[ "$backup" == "$generated_root"/.Runtime.backup.* ]] || fail "unsafe backup destination"
cleanup() {
	rm -rf "$scratch"
	if [[ -d "$staging" ]]; then
		rm -rf "$staging"
	fi
	if [[ -e "$backup" && ! -e "$destination" ]]; then
		mv "$backup" "$destination"
	fi
}
trap cleanup EXIT
guest_root="$scratch/guest"
mkdir -p "$guest_root"
zstd --decompress --stdout "$guest" | tar -xf - -C "$guest_root"
(
	cd "$guest_root"
	shasum -a 256 --check SHA256SUMS
)
cmp -s "$engine/runtime-manifest.json" "$guest_root/runtime-manifest.json" || \
	fail "engine and guest runtime manifests do not match"

mkdir -p "$staging/Frameworks" "$staging/Guest"
: > "$staging/Frameworks/.gitkeep"
: > "$staging/Guest/.gitkeep"
/usr/bin/ditto "$engine/Frameworks" "$staging/Frameworks"
cp "$engine/frameworks.txt" "$engine/SHA256SUMS" "$engine/runtime-manifest.json" "$staging/"
while IFS= read -r framework; do
	[[ -n "$framework" ]] || continue
	find "$staging/Frameworks/$framework" -maxdepth 1 -type f -perm -111 \
		-print -quit | grep -q . || fail "runtime framework lost its executable entry point: $framework"
done < "$staging/frameworks.txt"
for member in vmlinuz-virt initramfs-virt rootfs.ext4 workspace.ext4 packages.txt SHA256SUMS runtime-manifest.json; do
	[[ -f "$guest_root/$member" ]] || fail "guest transport is missing $member"
	cp "$guest_root/$member" "$staging/Guest/$member"
done
(
	cd "$staging"
	shasum -a 256 --check SHA256SUMS
)
(
	cd "$staging/Guest"
	shasum -a 256 --check SHA256SUMS
)
cmp -s "$staging/runtime-manifest.json" "$staging/Guest/runtime-manifest.json" || \
	fail "staged engine and guest runtime manifests do not match"

[[ ! -e "$backup" ]] || fail "runtime backup destination already exists"
if [[ -e "$destination" ]]; then
	mv "$destination" "$backup"
fi
if ! mv "$staging" "$destination"; then
	if [[ -e "$backup" ]]; then
		mv "$backup" "$destination"
	fi
	fail "could not commit the staged runtime"
fi
staging=""
if [[ -e "$backup" ]]; then
	rm -rf "$backup"
fi

printf 'Staged the verified full runtime at %s\n' "$destination"
