#!/usr/bin/env bash

set -euo pipefail

ALPINE_VERSION="3.24.1"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.1-aarch64.tar.gz"
ALPINE_SHA256="f55a90f69052c5bd6f92cb09a8f47065970830b194c917a006fb94028e721259"

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

case "$(uname -m)" in
	aarch64|arm64) ;;
	*) fail "rebuild remote dependencies on a native aarch64 host" ;;
esac

for tool in curl docker readelf sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || fail "required host tool is missing: $tool"
done

runtime_root="$(cd "$(dirname "$0")/.." && pwd -P)"
repository_root="$(cd "$runtime_root/../.." && pwd -P)"
[[ -f "$repository_root/remote/package-lock.json" ]] || fail "remote/package-lock.json is missing"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ivscode-alpine-deps.XXXXXX")"
archive="$scratch/alpine-minirootfs.tar.gz"
image="ivscode-alpine-deps:$ALPINE_VERSION"

cleanup() {
	docker image rm --force "$image" >/dev/null 2>&1 || true
	rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl --fail --location --retry 5 --retry-all-errors --output "$archive" "$ALPINE_URL"
printf '%s  %s\n' "$ALPINE_SHA256" "$archive" | sha256sum --check
docker import "$archive" "$image" >/dev/null

container_script="$(cat <<'IVSCODE_ALPINE_BUILD'
printf "%s\n" \
	https://dl-cdn.alpinelinux.org/alpine/v3.24/main \
	https://dl-cdn.alpinelinux.org/alpine/v3.24/community \
	> /etc/apk/repositories
apk add --no-cache \
	build-base \
	ca-certificates \
	git \
	krb5-dev \
	linux-headers \
	nodejs \
	nodejs-dev \
	npm \
	pkgconf \
	python3
# The host install is glibc-based. Rebuild from empty trees against the exact
# Node runtime and musl headers that will be present in the guest.
export npm_config_build_from_source=true
export npm_config_libc=musl
export npm_config_nodedir=/usr
export npm_config_runtime=node
export npm_config_target="$(node --print process.versions.node)"
# Alpine enables LTO in Node.js config.gypi. Addons inherit those flags, but
# GCC 15 cannot link spdlog's bundled fmt through fortified stdio.
export CFLAGS="${CFLAGS:-} -fno-lto"
export CXXFLAGS="${CXXFLAGS:-} -fno-lto"
export LDFLAGS="${LDFLAGS:-} -fno-lto"
npm install --global node-gyp-build
rm -rf /workspace/remote/node_modules
npm ci --foreground-scripts
cd /workspace/extensions/git
rm -rf /workspace/extensions/git/node_modules
npm ci --foreground-scripts
parcel_root=/workspace/remote/node_modules/@parcel
if [ -d "$parcel_root" ]; then
	find "$parcel_root" -mindepth 1 -maxdepth 1 -type d -name 'watcher-*' \
		-exec rm -rf -- {} +
fi
# node-gyp leaves duplicate linker inputs and platform-specific intermediate
# modules below obj.target. They are not runtime payloads, and some are not
# valid Node entry points on Linux (for example deviceid's windows.node).
find \
	/workspace/remote/node_modules \
	/workspace/extensions/git/node_modules \
	-type d -path '*/build/Release/obj.target' -prune \
	-exec rm -rf -- {} +
node - <<'NODE'
const { createRequire } = require('node:module');
const { readdirSync } = require('node:fs');
const path = require('node:path');

const remoteRequire = createRequire('/workspace/remote/package.json');
for (const name of [
	'@parcel/watcher',
	'@vscode/deviceid',
	'@vscode/fs-copyfile',
	'@vscode/native-watchdog',
	'@vscode/spdlog',
	'@vscode/sqlite3',
	'kerberos',
	'node-pty'
]) {
	remoteRequire(name);
	process.stdout.write(`loaded Alpine package ${name}\n`);
}

const gitRequire = createRequire('/workspace/extensions/git/package.json');
gitRequire('@vscode/fs-copyfile');
process.stdout.write('loaded Alpine extensions/git package @vscode/fs-copyfile\n');

let nativeCount = 0;
function loadNativeTree(root) {
	for (const entry of readdirSync(root, { withFileTypes: true })) {
		const candidate = path.join(root, entry.name);
		if (entry.isDirectory()) {
			loadNativeTree(candidate);
		} else if (entry.isFile() && entry.name.endsWith('.node')) {
			require(candidate);
			nativeCount++;
			process.stdout.write(`loaded Alpine native binding ${candidate}\n`);
		}
	}
}

loadNativeTree('/workspace/remote/node_modules');
loadNativeTree('/workspace/extensions/git/node_modules');
if (nativeCount === 0) {
	throw new Error('Alpine dependency rebuild produced no native bindings');
}
NODE
IVSCODE_ALPINE_BUILD
)"
sh -n -c "$container_script"

docker run --rm \
	--env GITHUB_TOKEN \
	--env npm_config_arch=arm64 \
	--env npm_config_cache=/workspace/.build/runtime/alpine-npm-cache \
	--volume "$repository_root:/workspace" \
	--workdir /workspace/remote \
	"$image" \
	/bin/sh -euxc "$container_script"

# VS Code deliberately discards Parcel's downloaded platform packages and
# packages the locally compiled binding instead.
parcel_root="$repository_root/remote/node_modules/@parcel"
if [[ -d "$parcel_root" ]]; then
	while IFS= read -r -d '' prebuilt; do
		[[ "$(dirname "$prebuilt")" == "$parcel_root" ]] || fail "unsafe Parcel prebuild path: $prebuilt"
		rm -rf "$prebuilt"
	done < <(find "$parcel_root" -mindepth 1 -maxdepth 1 -type d -name 'watcher-*' -print0)
fi

native_roots=(
	"$repository_root/remote/node_modules"
	"$repository_root/extensions/git/node_modules"
)
native_count=0
for native_root in "${native_roots[@]}"; do
	[[ -d "$native_root" ]] || fail "native dependency root is missing: $native_root"
	while IFS= read -r -d '' addon; do
		native_count=$((native_count + 1))
		readelf --file-header "$addon" | grep -Eq 'Machine:[[:space:]]+AArch64' || \
			fail "native addon is not AArch64: $addon"
		if readelf --dynamic "$addon" 2>/dev/null | grep -Eq 'Shared library: \[libc\.so\.6\]'; then
			fail "glibc runtime dependency leaked into Alpine addon: $addon"
		fi
	done < <(find "$native_root" -type f -name '*.node' -print0)
done
(( native_count > 0 )) || fail "remote dependency rebuild produced no native addons"

if [[ -n "${SUDO_USER:-}" ]]; then
	chown -R "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" \
		"$repository_root/remote/node_modules" \
		"$repository_root/extensions/git/node_modules" \
		"$repository_root/.build/runtime/alpine-npm-cache"
fi

printf 'Verified %d Alpine AArch64 native addons.\n' "$native_count"
