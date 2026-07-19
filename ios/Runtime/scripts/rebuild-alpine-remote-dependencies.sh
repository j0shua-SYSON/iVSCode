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

docker run --rm \
	--env GITHUB_TOKEN \
	--env npm_config_arch=arm64 \
	--env npm_config_cache=/workspace/.build/runtime/alpine-npm-cache \
	--volume "$repository_root:/workspace" \
	--workdir /workspace/remote \
	"$image" \
	/bin/sh -euxc '
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
			npm \
			pkgconf \
			python3
		npm install --global node-gyp-build
		npm ci
		cd /workspace/extensions/git
		npm ci
	'

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
		if readelf --version-info "$addon" 2>/dev/null | grep -q 'GLIBC_'; then
			fail "glibc symbol version leaked into Alpine addon: $addon"
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
