/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { cp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const iosRoot = path.resolve(scriptDirectory, '..');
const repositoryRoot = path.resolve(iosRoot, '..');

function readOption(name, fallback) {
	const index = process.argv.indexOf(name);
	return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const source = path.resolve(repositoryRoot, readOption('--source', '../vscode-web'));
const destination = path.resolve(iosRoot, readOption('--destination', 'iVSCode/Generated/Workbench'));
const shell = path.join(iosRoot, 'Shell');

async function assertDirectory(directory, label) {
	try {
		if ((await stat(directory)).isDirectory()) {
			return;
		}
	} catch {
		// Report one actionable error below.
	}
	throw new Error(`${label} does not exist: ${directory}`);
}

await assertDirectory(source, 'Packaged VS Code web build');
await assertDirectory(path.join(source, 'out'), 'VS Code web output');

await rm(destination, { recursive: true, force: true });
await mkdir(destination, { recursive: true });
await cp(source, destination, { recursive: true, force: true });
await cp(shell, destination, { recursive: true, force: true });

const metadata = {
	name: 'iVSCode',
	commit: process.env.GITHUB_SHA ?? process.env.BUILD_SOURCEVERSION ?? 'local',
	builtAt: new Date().toISOString(),
	source: path.relative(repositoryRoot, source).replaceAll('\\', '/')
};

await writeFile(path.join(destination, 'ivscode-build.json'), `${JSON.stringify(metadata, undefined, 2)}\n`);

const index = await readFile(path.join(destination, 'index.html'), 'utf8');
if (!index.includes('ivscode.bootstrap.js')) {
	throw new Error('Staged workbench is missing the iVSCode bootstrap reference.');
}

process.stdout.write(`Staged iVSCode workbench at ${destination}\n`);
