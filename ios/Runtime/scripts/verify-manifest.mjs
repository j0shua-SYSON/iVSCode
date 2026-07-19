#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const runtimeRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(await readFile(resolve(runtimeRoot, 'manifest.json'), 'utf8'));

assert.equal(manifest.schemaVersion, 2);
assert.equal(manifest.status, 'integrated-awaiting-device-validation');
assert.match(manifest.pins.utm.commit, /^[0-9a-f]{40}$/);
assert.match(manifest.pins.utm.referenceReleaseAsset.sha256, /^[0-9a-f]{64}$/);
assert.match(manifest.pins.qemu.sha256, /^[0-9a-f]{64}$/);
assert.match(manifest.pins.qemuKit.commit, /^[0-9a-f]{40}$/);
assert.match(manifest.pins.alpine.sha256, /^[0-9a-f]{64}$/);
assert.equal(manifest.runtime.jitRequired, false);
assert.equal(manifest.runtime.hvfCompiled, false);
assert.equal(manifest.runtime.privateHypervisorAPIs, false);
assert.deepEqual(manifest.runtime.disabledFeatures, ['spice', 'vnc', 'opengl', 'virglrenderer', 'gtk', 'sdl']);
assert.deepEqual(manifest.runtime.guestTargetList, ['aarch64-softmmu']);
assert.deepEqual(manifest.runtime.inProcessLauncher.symbols, [
	'qemu_init',
	'qemu_main_loop',
	'qemu_cleanup'
]);
assert.equal(manifest.runtime.inProcessLauncher.processSpawningAllowed, false);
assert.equal(manifest.guest.architecture, 'aarch64');
assert.equal(manifest.guest.memoryMiB.baseline, 512);
assert.equal(manifest.guest.network.guestListenAddress, '0.0.0.0');
assert.equal(manifest.guest.network.hostBindAddress, '127.0.0.1');
assert.equal(manifest.vscode.buildTask, 'vscode-reh-web-alpine-arm64-min');
assert.equal(manifest.releasePolicy.approvalGuaranteed, false);

const engineScript = await readFile(resolve(runtimeRoot, 'scripts/build-utm-engine.sh'), 'utf8');
const guestScript = await readFile(resolve(runtimeRoot, 'scripts/build-guest-image.sh'), 'utf8');
for (const pin of [manifest.pins.utm.commit, manifest.pins.qemu.source, manifest.pins.qemu.sha256]) {
	assert.ok(engineScript.includes(pin), `engine builder is missing pin ${pin}`);
}
assert.ok(engineScript.includes('HVF_FLAGS="--disable-hvf"'), 'engine builder must remove UTM private HVF');
for (const feature of manifest.runtime.disabledFeatures) {
	assert.ok(engineScript.includes(`--disable-${feature}`), `engine builder must disable ${feature}`);
}
for (const pin of [manifest.pins.alpine.minirootfs, manifest.pins.alpine.sha256]) {
	assert.ok(guestScript.includes(pin), `guest builder is missing pin ${pin}`);
}

console.log('iVSCode runtime manifest contract is internally consistent.');
