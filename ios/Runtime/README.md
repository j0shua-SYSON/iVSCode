# iVSCode Full Runtime

The full tier runs VS Code's existing Alpine ARM64 REH payload inside a bundled
ARM64 Linux guest. The guest is headless: iVSCode displays no VM desktop and
forwards only the loopback workbench endpoint. App-owned workspace storage is
mounted at `/workspace`.

## Why full-system ARM64 emulation

The REH payload already provides the correct remote filesystem, Node extension
host, PTY backend, tasks, debug adapters, search, Git, native modules, and
language servers. Its supported Alpine ARM64 build maps directly to an ARM64
guest. A browser-only build cannot provide those process-backed features, while
an i386 user-mode layer would require an unsupported 32-bit REH target.

The pinned runtime uses UTM SE's threaded-code interpreter. It does not require
JIT, a jailbreak, or private hypervisor access. The VM is intentionally smaller
than a general UTM machine:

- ARM64 `virt` machine only; no display, audio, USB, or desktop stack.
- two guest CPUs and a 768 MiB initial ceiling, subject to device-class tuning.
- read-only compressed system image plus a writable app-container workspace.
- virtio block, network, entropy, serial control, and shared-folder devices only.
- one loopback-forwarded server port with a per-launch connection token.

## Milestone gate

The full runtime is complete only when a physical iPad can, without a companion
computer or server:

1. boot the bundled guest after a cold app launch;
2. open and persist the app-container workspace;
3. start the REH server and reconnect after foreground suspension;
4. create an interactive terminal and run a task;
5. use Git and ripgrep search;
6. activate one web extension and one bundled Node workspace extension;
7. stop cleanly without corrupting the workspace image.

Simulator compilation alone is not runtime evidence. The GitHub workflow first
proves the native shell and browser recovery tier; the runtime workflow will add
the guest image and UTM-SE integration behind these device-level gates.
