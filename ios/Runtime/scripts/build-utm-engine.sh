#!/usr/bin/env bash

set -euo pipefail

UTM_COMMIT="048ca7498ea3a374439149d51739d94c5300bcda"
QEMU_URL="https://github.com/utmapp/qemu/releases/download/v10.0.2-utm/qemu-10.0.2-utm.tar.xz"
QEMU_SHA256="f1d7357547a71ae3339a115d5c8f2b72e3b0089531d67c2aca43326d320ac6ca"
UPSTREAM_TARGETS="aarch64-softmmu,i386-softmmu,ppc-softmmu,ppc64-softmmu,riscv64-softmmu,x86_64-softmmu,m68k-softmmu"
IVSCODE_TARGETS="aarch64-softmmu"

usage() {
	printf 'Usage: %s /path/to/pinned/UTM-checkout\n' "$(basename "$0")" >&2
}

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

for tool in curl git python3 shasum xcodebuild; do
	command -v "$tool" >/dev/null 2>&1 || fail "required tool is missing: $tool"
done

xcode_version="$(xcodebuild -version | head -n 1)"
[[ "$xcode_version" =~ ^Xcode\ 26\.0(\.[0-9]+)?$ ]] || \
	fail "selected toolchain is $xcode_version, expected the Xcode 26.0 patch train"

[[ $# -eq 1 ]] || {
	usage
	exit 64
}

UTM_DIR="$1"
[[ -d "$UTM_DIR/.git" ]] || fail "not a UTM Git checkout: $UTM_DIR"
UTM_DIR="$(cd "$UTM_DIR" && pwd -P)"

actual_commit="$(git -C "$UTM_DIR" rev-parse HEAD)"
[[ "$actual_commit" == "$UTM_COMMIT" ]] || fail "UTM checkout is $actual_commit, expected $UTM_COMMIT"

if ! git -C "$UTM_DIR" diff --quiet -- scripts/build_dependencies.sh; then
	fail "scripts/build_dependencies.sh already has tracked changes"
fi

sources_file="$UTM_DIR/patches/sources"
build_script="$UTM_DIR/scripts/build_dependencies.sh"
[[ -f "$sources_file" && -f "$build_script" ]] || fail "pinned UTM dependency files are missing"
grep -Fq "$QEMU_URL" "$sources_file" || fail "UTM's QEMU source pin no longer matches the reviewed URL"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ivscode-utm.XXXXXX")"
backup="$scratch/build_dependencies.sh"
cp -p "$build_script" "$backup"

cleanup() {
	cp -p "$backup" "$build_script"
	rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - "$build_script" "$UPSTREAM_TARGETS" "$IVSCODE_TARGETS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
upstream = "--target-list=" + sys.argv[2]
replacement = "--target-list=" + sys.argv[3]
text = path.read_text(encoding="utf-8")
count = text.count(upstream)
if count != 1:
    raise SystemExit(f"expected exactly one reviewed TCI target list, found {count}")
text = text.replace(upstream, replacement)
private_hvf = 'HVF_FLAGS="--enable-hvf-private"'
disabled_hvf = 'HVF_FLAGS="--disable-hvf"'
count = text.count(private_hvf)
if count != 1:
    raise SystemExit(f"expected exactly one private-HVF switch, found {count}")
text = text.replace(private_hvf, disabled_hvf)
platform_flags = 'QEMU_PLATFORM_BUILD_FLAGS="--disable-debug-info --enable-shared-lib --disable-cocoa --disable-coreaudio --disable-slirp-smbd --enable-ucontext --with-coroutine=libucontext $HVF_FLAGS $TCI_BUILD_FLAGS"'
headless_flags = platform_flags[:-1] + ' --disable-spice --disable-vnc --disable-opengl --disable-virglrenderer --disable-gtk --disable-sdl"'
count = text.count(platform_flags)
if count != 1:
    raise SystemExit(f"expected exactly one reviewed iOS QEMU flag set, found {count}")
text = text.replace(platform_flags, headless_flags)

# UTM fixed these Objective-C flag mappings after 4.7.5. Without the target
# tuple in OBJCFLAGS, dependencies can be compiled against the build SDK rather
# than iVSCode's supported deployment target.
meson_objc_cflags = 'echo "objc_args = [${CFLAGS:+$(meson_quote $CFLAGS)}]" >> $cross'
meson_objc_objcflags = 'echo "objc_args = [${OBJCFLAGS:+$(meson_quote $OBJCFLAGS)}]" >> $cross'
count = text.count(meson_objc_cflags)
if count != 1:
    raise SystemExit(f"expected exactly one Meson Objective-C CFLAGS mapping, found {count}")
text = text.replace(meson_objc_cflags, meson_objc_objcflags)

upstream_minimum = 'IOS_SDKMINVER="11.0"'
ivscode_minimum = 'IOS_SDKMINVER="17.0"'
count = text.count(upstream_minimum)
if count != 1:
    raise SystemExit(f"expected exactly one reviewed iOS deployment target, found {count}")
text = text.replace(upstream_minimum, ivscode_minimum)

path.write_text(text, encoding="utf-8")
PY

archive="$scratch/qemu-10.0.2-utm.tar.xz"
curl --fail --location --retry 5 --retry-all-errors --output "$archive" "$QEMU_URL"
printf '%s  %s\n' "$QEMU_SHA256" "$archive" | shasum -a 256 --check

# Seed UTM's normal download location. Its own download() function will unpack
# this verified archive and apply patches/qemu-10.0.2-utm.patch before build.
qemu_build_dir="$UTM_DIR/build-iOS-TCI-arm64"
mkdir -p "$qemu_build_dir"
cp "$archive" "$qemu_build_dir/qemu-10.0.2-utm.tar.xz"
[[ -f "$UTM_DIR/patches/qemu-10.0.2-utm.patch" ]] || fail "pinned UTM QEMU patch is missing"

printf 'Building UTM iOS-TCI arm64 dependencies at %s\n' "$UTM_COMMIT"
printf 'QEMU source verified as %s\n' "$QEMU_SHA256"
(
	cd "$UTM_DIR"
	NCPU=1 ./scripts/build_dependencies.sh -p ios-tci -a arm64
)

framework="$UTM_DIR/sysroot-iOS-TCI-arm64/Frameworks/qemu-aarch64-softmmu.framework"
binary="$framework/qemu-aarch64-softmmu"
[[ -d "$framework" && -f "$binary" ]] || fail "upstream build completed without $framework"

printf 'Engine sysroot ready: %s\n' "$UTM_DIR/sysroot-iOS-TCI-arm64"
