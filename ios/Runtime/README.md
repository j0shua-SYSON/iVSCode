# iVSCode Full Runtime

This directory specifies the full, process-backed tier: VS Code's existing
Alpine ARM64 REH-web payload inside a small headless Linux guest. The guest is
not a VM desktop. A `WKWebView` talks to one authenticated, loopback-forwarded
HTTP/WebSocket endpoint, while the guest supplies the extension host, PTYs,
tasks, debug adapters, search, Git, native modules, and language servers.

**Current state:** the pinned QEMU engine, QEMUKit control plane, Alpine guest,
and VS Code server are integrated into the native target and assembled by the
full-runtime GitHub Actions workflow. The image has not yet booted on a physical
iPhone or iPad, and App Store approval is not established. Do not label the full
tier device-validated from a simulator build or successful artifact generation.

## Runtime architecture

The no-JIT engine is UTM SE 4.7.5 at commit
`048ca7498ea3a374439149d51739d94c5300bcda`. Its dependency manifest pins QEMU
`10.0.2-utm`; `manifest.json` also pins the QEMU archive digest, QEMUKit commit,
and Alpine 3.24.1 minirootfs digest. It records the published `UTM-SE.ipa`
digest as provenance evidence only; iVSCode does not embed or repackage that
application.

Only `aarch64-softmmu` is built. The guest uses direct kernel boot and the
`virt` board, with no firmware, display, GPU, audio, USB, SPICE, GStreamer, or
desktop environment in the shipped closure. Its baseline is two emulated CPUs
and 512 MiB RAM. A 768 MiB profile is only appropriate after testing memory
pressure and obtaining any required increased-memory entitlement.

iOS cannot spawn a QEMU child process. The native target therefore loads
`qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu` in-process and calls the
three exported entry points used by UTM's `UTMQemuSystem.m`:

1. `qemu_init(int, const char *[], const char *[])`
2. `qemu_main_loop(void)`
3. `qemu_cleanup(void)`

`IVQemuLauncher` runs those calls on a dedicated pthread. QEMUKit's
`QEMUVirtualMachine` owns QMP and guest-agent state, while `IVPipeInterface`
adapts UTM's headless four-FIFO transport: QMP `.in`/`.out` and guest-agent
`.in`/`.out`. No SPICE client is linked or needed.

The pinned QEMUKit contract is
`QEMUVirtualMachine.start(launcher:interface:)`; the launcher conforms to
`QEMULauncher`, and the pipe endpoint conforms to `QEMUInterface`. The dynamic
library loader stays in the launcher; iVSCode never attempts `Process`, `fork`,
or `spawn`, which are unavailable for this use on iOS.

Start QEMU paused with `-S`, connect QMP, negotiate capabilities, then continue
the VM. On scene backgrounding, ask the guest helper to shut down through the
guest agent, wait for QMP shutdown, and only then fall back to `qemuQuit`.
Use one bounded `beginBackgroundTask` only to finish that shutdown sequence;
the expiration path may issue a safe QMP quit but never cancels QEMU from a
foreign thread. A wedged engine remains process-owned and disables further
full-runtime launches until the app restarts. There is deliberately no fake
audio or location background mode and no claim that the VM continues while
suspended.

## Hosted builds

All expensive work belongs in GitHub Actions. Nothing here requires a local
Xcode, QEMU, Linux VM, package install, or write to `C:`.

The macOS engine job checks out the exact UTM commit and follows UTM's own iOS
TCI dependency build:

```sh
[[ "$(xcode-select -p)" == /Applications/Xcode_26.0.app* ]] || \
  sudo xcode-select -s /Applications/Xcode_26.0.app
brew uninstall cmake
brew install bison pkg-config gettext glib-utils libgpg-error nasm make meson
python3 -m venv "$GITHUB_WORKSPACE/.build/utm-python"
"$GITHUB_WORKSPACE/.build/utm-python/bin/python" -m pip install \
  setuptools six pyparsing distlib mako pyyaml
export PATH="/usr/local/opt/bison/bin:/opt/homebrew/opt/bison/bin:$PATH"
rm -f /usr/local/lib/pkgconfig/*.pc
bash ios/Runtime/scripts/build-utm-engine.sh "$GITHUB_WORKSPACE/.build/UTM"
bash ios/Runtime/scripts/collect-framework-closure.sh \
  "$GITHUB_WORKSPACE/.build/UTM/sysroot-iOS-TCI-arm64" \
  "$GITHUB_WORKSPACE/.build/runtime/engine"
```

UTM upstream uses Xcode 26 and `NCPU=1` for this build. The builder makes three
auditable, fail-closed changes in its temporary checkout: it replaces UTM's
seven-architecture TCI target list with only `aarch64-softmmu`, replaces the
unused iOS `--enable-hvf-private` switch with `--disable-hvf`, and disables the
SPICE, VNC, OpenGL, virglrenderer, GTK, and SDL features that a headless guest
cannot use. This keeps private hypervisor code and display stacks out of an
interpreter-only App Store binary. It then executes:

```sh
NCPU=1 ./scripts/build_dependencies.sh -p ios-tci -a arm64
```

For comparison, UTM's complete SE application command is
`./scripts/build_utm.sh -k iphoneos -s iOS-SE -a arm64 -o UTM`, producing an
unsigned `UTM.xcarchive`. iVSCode intentionally does not run that packaging
step or embed the UTM application; it consumes the smaller QEMU framework
closure and its own launcher/UI.

The collector starts at `qemu-aarch64-softmmu.framework`, follows the actual
Mach-O `@rpath` dependency graph with `otool`, and emits only that framework
closure plus checksums. It fails on an unresolved non-system dependency. This
removes unused architectures and UI frameworks from the app artifact without
guessing at QEMU configure flags. Building fewer dependencies is a later,
measured optimization because UTM's upstream script still compiles some SPICE
and GStreamer dependencies even though the headless QEMU binary does not link
or ship them.

The collector also requires every emitted Mach-O to be arm64-only, rejects a
Hypervisor framework/symbol dependency, and fails if a disabled SPICE,
GStreamer, virgl, or epoxy framework leaks into the closure. Those are static
gates; they do not replace a physical-device TCI boot test.

The QEMU archive itself is digest-verified. UTM's other dependency tarballs are
version-addressed by the pinned upstream commit but are not all independently
digest-locked by this scaffold. Lock those inputs or attach verifiable build
provenance before treating an engine artifact as production supply-chain
evidence.

The guest job uses GitHub's native `ubuntu-24.04-arm` public runner. It first
builds `vscode-reh-web-alpine-arm64-min`, rebuilds both server and bundled Git
extension native dependencies inside Alpine aarch64 containers, and then passes
the extracted server directory to:

```sh
sudo bash ios/Runtime/scripts/build-guest-image.sh \
  --server .build/vscode-reh-web-alpine-arm64 \
  --output "$RUNNER_TEMP/ivscode-alpine-aarch64.tar.zst"
```

The image builder verifies Alpine before extraction, installs only the
headless base packages, records exact installed versions, and emits a kernel,
initramfs, compact ext4 root seed, and a sparse workspace template. The root
seed is copied to the app container on first launch; it is not written in the
signed application bundle. The workspace image is separately copied and may
be enlarged before boot; the guest grows it with `resize2fs`.

Alpine's minirootfs is digest-pinned, but the `v3.24` APK repositories move as
security updates are published. Preserve and promote a tested guest artifact
by its emitted checksum. A production rebuild policy should additionally use
an immutable package snapshot or a complete mirrored package lock.

The `.tar.zst` is a CI transport artifact. `stage-runtime.sh` verifies and
unpacks its members before Xcode adds them to the application; the iOS app does
not link a Zstandard decompressor. The engine closure separately travels as a
tar archive so GitHub artifact transport cannot erase Mach-O executable bits.
IPA compression handles the mostly empty ext4 space, and first launch copies
only the raw seeds into the app container.

## Boot contract

The native launcher assembles arguments from `manifest.json`, including:

```text
-nodefaults -machine virt,highmem=off -cpu cortex-a72
-accel tcg,thread=multi,tb-size=64 -smp 2 -m 512
-display none -serial null -S -no-reboot
-kernel <vmlinuz-virt> -initrd <initramfs-virt>
-append "console=ttyAMA0 root=/dev/vda rootfstype=ext4 rw rootwait modules=virtio_pci,virtio_blk,virtio_net"
```

Attach the copied root image as `/dev/vda`, the workspace as `/dev/vdb`, a
virtio RNG, virtio network, virtio serial guest-agent port, and QMP/guest-agent
pipe chardevs. QEMU SLIRP forwards only
`127.0.0.1:<ephemeral-host-port>` to guest port 8000. Outbound networking stays
enabled for Git and extension services.

The app generates a cryptographically random base64url token for every launch,
writes it to an app-container file with data protection and mode `0600`, then passes
`-fw_cfg name=opt/ivscode/token,file=<protected-token-file>`. This keeps the
secret out of the QEMU argument vector. The guest copies it to
`/run/ivscode/token` and starts the server with `--connection-token-file`.
Still redact the entire `-fw_cfg` pair from diagnostics. A loopback host port is
selected immediately before launch. Port probing has a small race; a bind
failure is fail-closed and returns to the instant workspace in this revision.

After QMP reports the VM running and guest-agent execution of
`/sbin/rc-service ivscode status` succeeds,
bootstrap the webview exactly once at
`http://127.0.0.1:<host-port>/?tkn=<percent-encoded-token>`. The existing
REH-web handler stores that value in its `vscode-tkn` cookie and redirects to a
clean URL. Always repeat the token bootstrap after a VM restart; cookies are
host-scoped rather than port-scoped, so a cookie from the previous ephemeral
port must never be treated as current authentication.

## Device and release gates

The runtime is complete only when a physical supported iPad can, without a
companion computer or remote server:

1. cold-boot the bundled guest and authenticate the workbench;
2. persist and reopen files in the app-container workspace;
3. create an interactive terminal and run a task;
4. use Git and ripgrep search;
5. activate one web extension and one bundled Node workspace extension;
6. background, foreground, reconnect, and shut down without filesystem damage;
7. remain usable under sustained memory and thermal pressure with TCI.

UTM SE demonstrates that interpreter-only emulation can ship on iOS, but it
does not pre-approve iVSCode. App Review guideline 2.5.2 makes downloaded guest
executables, extensions, compilers, and language servers a material product
policy risk. The App Store profile should bundle the reviewed guest/server
payload and prevent post-review executable guest updates until counsel and App
Review guidance say otherwise. Sideloaded builds can be a separate profile.

The baseline App Store build should use no JIT/dynamic-codesigning entitlement
and no fabricated background mode. Treat increased-memory-limit and
extended-virtual-addressing as optional entitlements that require a demonstrated
need and an Apple-approved signing profile, not runtime prerequisites.

QEMU's GPL-2.0 obligations and the complete transitive framework closure also
need release counsel, corresponding-source publication, notices, and an SBOM.
See `LICENSES.md`; UTM's presence in the App Store is evidence, not a legal or
review guarantee.

## Authoritative references

- [UTM 4.7.5 source](https://github.com/utmapp/UTM/tree/048ca7498ea3a374439149d51739d94c5300bcda)
- [UTM dependency build instructions](https://github.com/utmapp/UTM/blob/048ca7498ea3a374439149d51739d94c5300bcda/Documentation/Dependencies.md)
- [UTM in-process QEMU launcher](https://github.com/utmapp/UTM/blob/048ca7498ea3a374439149d51739d94c5300bcda/Services/UTMQemuSystem.m)
- [UTM FIFO QMP/guest-agent interface](https://github.com/utmapp/UTM/blob/048ca7498ea3a374439149d51739d94c5300bcda/Services/UTMPipeInterface.swift)
- [UTM iOS installation and SE/JIT distinction](https://docs.getutm.app/installation/ios/)
- [QEMUKit pinned source](https://github.com/utmapp/QEMUKit/tree/589765abff27a8764d58b1a90999a204ac09881e)
- [Alpine 3.24 aarch64 releases](https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [GitHub-hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
