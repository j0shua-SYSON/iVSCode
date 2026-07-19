#!/usr/bin/env bash

set -euo pipefail

ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.1-aarch64.tar.gz"
ALPINE_SHA256="f55a90f69052c5bd6f92cb09a8f47065970830b194c917a006fb94028e721259"
ALPINE_BRANCH="v3.24"
ROOT_UUID="49565343-4f44-4500-8000-000000000001"
WORKSPACE_UUID="49565343-4f44-4500-8000-000000000002"

usage() {
	cat >&2 <<EOF
Usage: $(basename "$0") --server /path/to/extracted/reh-server --output /path/to/ivscode-alpine-aarch64.tar.zst

Run as root on a native aarch64 Linux host. The output path must not exist.
EOF
}

fail() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

SERVER_INPUT=""
OUTPUT=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--server)
			[[ $# -ge 2 ]] || fail "--server requires a value"
			SERVER_INPUT="$2"
			shift 2
			;;
		--output)
			[[ $# -ge 2 ]] || fail "--output requires a value"
			OUTPUT="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			fail "unknown argument: $1"
			;;
	esac
done

[[ -n "$SERVER_INPUT" && -n "$OUTPUT" ]] || {
	usage
	exit 64
}
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "the guest builder must run as root"
case "$(uname -m)" in
	aarch64|arm64) ;;
	*) fail "use a native aarch64 runner, not cross-user emulation" ;;
esac

for tool in chroot cp curl find mkfs.ext4 sha256sum tar truncate zstd; do
	command -v "$tool" >/dev/null 2>&1 || fail "required host tool is missing: $tool"
done
[[ -d "$SERVER_INPUT" ]] || fail "server directory does not exist: $SERVER_INPUT"
[[ ! -e "$OUTPUT" ]] || fail "refusing to overwrite output: $OUTPUT"

SERVER_INPUT="$(cd "$SERVER_INPUT" && pwd -P)"
OUTPUT_PARENT="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
OUTPUT="$OUTPUT_PARENT/$(basename "$OUTPUT")"

server_markers=()
while IFS= read -r -d '' marker; do
	server_markers+=("$marker")
done < <(find "$SERVER_INPUT" -type f -path '*/out/server-main.js' -print0)
[[ ${#server_markers[@]} -eq 1 ]] || fail "expected one out/server-main.js below the server directory, found ${#server_markers[@]}"
SERVER_ROOT="$(cd "$(dirname "${server_markers[0]}")/.." && pwd -P)"

server_launchers=()
while IFS= read -r -d '' launcher; do
	server_launchers+=("$launcher")
done < <(find "$SERVER_ROOT/bin" -maxdepth 1 -type f -perm /111 -print0)
[[ ${#server_launchers[@]} -eq 1 ]] || fail "expected one top-level executable server launcher, found ${#server_launchers[@]}"
SERVER_LAUNCHER="$(basename "${server_launchers[0]}")"

remote_clis=()
while IFS= read -r -d '' remote_cli; do
	remote_clis+=("$remote_cli")
done < <(find "$SERVER_ROOT/bin/remote-cli" -maxdepth 1 -type f -perm /111 -print0)
[[ ${#remote_clis[@]} -eq 1 ]] || fail "expected one packaged remote CLI, found ${#remote_clis[@]}"
REMOTE_CLI="$(basename "${remote_clis[0]}")"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ivscode-guest.XXXXXX")"
root="$scratch/root"
bundle="$scratch/bundle"
archive="$scratch/alpine-minirootfs.tar.gz"
mkdir -p "$root" "$bundle"
temporary_output="$OUTPUT.partial"
cleanup() {
	rm -rf "$scratch"
	if [[ -f "$temporary_output" ]]; then
		rm -f "$temporary_output"
	fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl --fail --location --retry 5 --retry-all-errors --output "$archive" "$ALPINE_URL"
printf '%s  %s\n' "$ALPINE_SHA256" "$archive" | sha256sum --check
tar -xzf "$archive" -C "$root"

cat > "$root/etc/apk/repositories" <<EOF
https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main
https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/community
EOF
cp -L /etc/resolv.conf "$root/etc/resolv.conf"

packages=(
	alpine-base
	bash
	ca-certificates
	curl
	e2fsprogs
	git
	libgcc
	libstdc++
	linux-virt
	openssh-client
	qemu-guest-agent
	qemu-guest-agent-openrc
	ripgrep
)
chroot "$root" /sbin/apk upgrade --available --no-cache
chroot "$root" /sbin/apk add --no-cache "${packages[@]}"
printf 'nameserver 10.0.2.3\n' > "$root/etc/resolv.conf"

mkdir -p "$root/opt/ivscode/server"
cp -a "$SERVER_ROOT/." "$root/opt/ivscode/server/"
if [[ "$SERVER_LAUNCHER" != "ivscode-server" ]]; then
	ln -s "$SERVER_LAUNCHER" "$root/opt/ivscode/server/bin/ivscode-server"
fi
mkdir -p "$root/usr/local/bin"
ln -s "/opt/ivscode/server/bin/remote-cli/$REMOTE_CLI" "$root/usr/local/bin/code"
chown -R 0:0 "$root/opt/ivscode/server"
chroot "$root" /opt/ivscode/server/node --version >/dev/null
chroot "$root" /opt/ivscode/server/bin/helpers/check-requirements.sh >/dev/null

chroot "$root" /usr/sbin/adduser -D -u 1000 -h /workspace/home -s /bin/ash ivscode
chroot "$root" /usr/bin/passwd -l ivscode >/dev/null
chroot "$root" /usr/bin/passwd -l root >/dev/null

runtime_root="$(cd "$(dirname "$0")/.." && pwd -P)"
install -D -m 0755 "$runtime_root/guest/etc/init.d/ivscode" "$root/etc/init.d/ivscode"
install -D -m 0755 "$runtime_root/guest/usr/local/sbin/ivscode-poweroff" "$root/usr/local/sbin/ivscode-poweroff"
mkdir -p "$root/workspace" "$root/run/ivscode"

cat > "$root/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
printf 'ivscode\n' > "$root/etc/hostname"
cat > "$root/etc/fstab" <<'EOF'
/dev/vda  /          ext4  rw,noatime        0  1
/dev/vdb  /workspace ext4  noauto,noatime    0  0
EOF
cat > "$root/etc/modules" <<'EOF'
qemu_fw_cfg
EOF

add_service() {
	local service="$1"
	local runlevel="$2"
	if [[ -x "$root/etc/init.d/$service" ]]; then
		chroot "$root" /sbin/rc-update add "$service" "$runlevel"
	fi
}

for service in devfs dmesg mdev hwdrivers; do add_service "$service" sysinit; done
for service in modules sysctl hostname bootmisc syslog localmount; do add_service "$service" boot; done
for service in mount-ro killprocs savecache; do add_service "$service" shutdown; done
add_service networking default
add_service qemu-guest-agent default
add_service ivscode default

chroot "$root" /sbin/apk info -vv | LC_ALL=C sort > "$bundle/packages.txt"
cp "$runtime_root/manifest.json" "$bundle/runtime-manifest.json"

[[ -f "$root/boot/vmlinuz-virt" ]] || fail "linux-virt did not install /boot/vmlinuz-virt"
[[ -f "$root/boot/initramfs-virt" ]] || fail "linux-virt did not install /boot/initramfs-virt"
cp "$root/boot/vmlinuz-virt" "$bundle/vmlinuz-virt"
cp "$root/boot/initramfs-virt" "$bundle/initramfs-virt"

root_used_kib="$(du -sk "$root" | awk '{print $1}')"
root_mib="$(( (root_used_kib + 1023) / 1024 + 128 ))"
root_image="$bundle/rootfs.ext4"
workspace_image="$bundle/workspace.ext4"
truncate -s "${root_mib}M" "$root_image"
truncate -s 64M "$workspace_image"

export E2FSPROGS_FAKE_TIME="${SOURCE_DATE_EPOCH:-1}"
mkfs.ext4 -F -q -U "$ROOT_UUID" -L IVSCODE_ROOT \
	-E lazy_itable_init=0,lazy_journal_init=0 -d "$root" "$root_image"
mkfs.ext4 -F -q -U "$WORKSPACE_UUID" -L IVSCODE_WORKSPACE \
	-E lazy_itable_init=0,lazy_journal_init=0 "$workspace_image"

(
	cd "$bundle"
	sha256sum initramfs-virt packages.txt rootfs.ext4 runtime-manifest.json vmlinuz-virt workspace.ext4 > SHA256SUMS
)

[[ ! -e "$temporary_output" ]] || fail "refusing to overwrite partial output: $temporary_output"
tar --sort=name --mtime="@${SOURCE_DATE_EPOCH:-1}" --owner=0 --group=0 --numeric-owner \
	--zstd -cf "$temporary_output" -C "$bundle" .
mv "$temporary_output" "$OUTPUT"

printf 'Guest artifact ready: %s\n' "$OUTPUT"
printf 'Uncompressed root image: %s MiB (%s MiB free-build headroom)\n' "$root_mib" 128
