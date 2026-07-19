/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import * as vscode from 'vscode';

const scheme = 'code-mobile';
const apiRoot = '/__code_mobile__/fs';
const revisionPollInterval = 1000;

interface JsonObject {
	readonly [key: string]: JsonValue;
}

type JsonValue = JsonObject | JsonValue[] | boolean | number | string | null;

interface ErrorDetails {
	readonly code: string | undefined;
	readonly message: string | undefined;
}

/** A watch policy retained while the native service exposes only a global revision. */
interface WatchRegistration {
	readonly uri: vscode.Uri;
	readonly recursive: boolean;
	readonly excludes: readonly string[];
}

class CodeMobileFileSystemProvider implements vscode.FileSystemProvider, vscode.Disposable {
	private readonly changeEmitter = new vscode.EventEmitter<vscode.FileChangeEvent[]>();
	private readonly watches = new Map<number, WatchRegistration>();
	private nextWatchId = 0;
	private watchGeneration = 0;
	private revision: string | undefined;
	private revisionPollTimer: number | undefined;
	private isDisposed = false;

	readonly onDidChangeFile = this.changeEmitter.event;

	watch(
		uri: vscode.Uri,
		options: { readonly recursive: boolean; readonly excludes: readonly string[] },
	): vscode.Disposable {
		const watchId = this.nextWatchId++;
		this.watches.set(watchId, {
			uri,
			recursive: options.recursive,
			excludes: [...options.excludes],
		});

		if (this.watches.size === 1) {
			this.watchGeneration++;
			this.revision = undefined;
			this.scheduleRevisionPoll(0);
		}

		return new vscode.Disposable(() => {
			this.watches.delete(watchId);
			if (this.watches.size === 0) {
				this.stopRevisionPolling();
			}
		});
	}

	async stat(uri: vscode.Uri): Promise<vscode.FileStat> {
		const response = await this.request('stat', uri, [['path', resourcePath(uri)]]);
		const value = await readJson(response, vscode.l10n.t("The native file service returned invalid file metadata."));
		return parseFileStat(value);
	}

	async readDirectory(uri: vscode.Uri): Promise<[string, vscode.FileType][]> {
		const response = await this.request('read-directory', uri, [['path', resourcePath(uri)]]);
		const value = await readJson(
			response,
			vscode.l10n.t("The native file service returned an invalid directory listing."),
		);
		return parseDirectoryEntries(value);
	}

	async createDirectory(uri: vscode.Uri): Promise<void> {
		await this.request('create-directory', uri, [['path', resourcePath(uri)]], { method: 'POST' });
	}

	async readFile(uri: vscode.Uri): Promise<Uint8Array> {
		const response = await this.request('read-file', uri, [['path', resourcePath(uri)]]);
		return new Uint8Array(await response.arrayBuffer());
	}

	async writeFile(
		uri: vscode.Uri,
		content: Uint8Array,
		options: { readonly create: boolean; readonly overwrite: boolean },
	): Promise<void> {
		await this.request('write-file', uri, [
			['path', resourcePath(uri)],
			['create', String(options.create)],
			['overwrite', String(options.overwrite)],
		], {
			method: 'PUT',
			headers: { 'Content-Type': 'application/octet-stream' },
			body: requestBody(content),
		});
	}

	async delete(uri: vscode.Uri, options: { readonly recursive: boolean }): Promise<void> {
		await this.request('entry', uri, [
			['path', resourcePath(uri)],
			['recursive', String(options.recursive)],
		], { method: 'DELETE' });
	}

	async rename(oldUri: vscode.Uri, newUri: vscode.Uri, options: { readonly overwrite: boolean }): Promise<void> {
		await this.requestJson('rename', oldUri, {
			oldPath: resourcePath(oldUri),
			newPath: resourcePath(newUri),
			overwrite: options.overwrite,
		});
	}

	async copy(source: vscode.Uri, destination: vscode.Uri, options: { readonly overwrite: boolean }): Promise<void> {
		await this.requestJson('copy', source, {
			oldPath: resourcePath(source),
			newPath: resourcePath(destination),
			overwrite: options.overwrite,
		});
	}

	dispose(): void {
		this.isDisposed = true;
		this.stopRevisionPolling();
		this.watches.clear();
		this.changeEmitter.dispose();
	}

	private async requestJson(operation: string, resource: vscode.Uri, body: JsonObject): Promise<void> {
		await this.request(operation, resource, [], {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
		});
	}

	private async request(
		operation: string,
		resource: vscode.Uri | undefined,
		query: readonly (readonly [string, string])[],
		init?: RequestInit,
	): Promise<Response> {
		const searchParams = new URLSearchParams();
		for (const [name, value] of query) {
			searchParams.set(name, value);
		}

		const queryString = searchParams.toString();
		const url = `${apiRoot}/${operation}${queryString ? `?${queryString}` : ''}`;

		let response: Response;
		try {
			response = await fetch(url, { ...init, cache: 'no-store', credentials: 'same-origin' });
		} catch {
			throw vscode.FileSystemError.Unavailable(resource ?? vscode.l10n.t("The native file service is unavailable."));
		}

		if (!response.ok) {
			throw await fileSystemErrorFromResponse(response, resource);
		}

		return response;
	}

	private scheduleRevisionPoll(delay: number): void {
		if (this.isDisposed || this.watches.size === 0 || this.revisionPollTimer !== undefined) {
			return;
		}

		this.revisionPollTimer = setTimeout(() => {
			this.revisionPollTimer = undefined;
			void this.pollRevision(this.watchGeneration);
		}, delay);
	}

	private stopRevisionPolling(): void {
		this.watchGeneration++;
		if (this.revisionPollTimer !== undefined) {
			clearTimeout(this.revisionPollTimer);
			this.revisionPollTimer = undefined;
		}
		this.revision = undefined;
	}

	private async pollRevision(watchGeneration: number): Promise<void> {
		try {
			const response = await this.request('revision', undefined, []);
			const nextRevision = await readRevision(response);

			if (this.watches.size === 0 || watchGeneration !== this.watchGeneration) {
				return;
			}

			if (this.revision !== undefined && this.revision !== nextRevision) {
				// The revision endpoint exposes a global counter, not changed paths. Keep each
				// registration's recursive/exclude policy intact, but invalidate only its root:
				// clients can rescan using that policy without us inventing incorrect child events.
				const watchedRoots = new Map<string, vscode.Uri>();
				for (const watch of this.watches.values()) {
					watchedRoots.set(watch.uri.toString(), watch.uri);
				}
				this.changeEmitter.fire(Array.from(watchedRoots.values(), uri => ({
					type: vscode.FileChangeType.Changed,
					uri,
				})));
			}

			this.revision = nextRevision;
		} catch {
			// A transient service failure must not stop future watch polling.
		} finally {
			if (watchGeneration === this.watchGeneration) {
				this.scheduleRevisionPoll(revisionPollInterval);
			}
		}
	}
}

function resourcePath(uri: vscode.Uri): string {
	return uri.path || '/';
}

async function readJson(response: Response, invalidResponseMessage: string): Promise<JsonValue> {
	const text = await response.text();
	try {
		return JSON.parse(text) as JsonValue;
	} catch {
		throw vscode.FileSystemError.Unavailable(invalidResponseMessage);
	}
}

function parseFileStat(value: JsonValue): vscode.FileStat {
	let object = asJsonObject(value);
	if (object && asJsonObject(object.stat)) {
		object = asJsonObject(object.stat);
	}

	if (!object) {
		throw vscode.FileSystemError.Unavailable(vscode.l10n.t("The native file service returned invalid file metadata."));
	}

	const type = parseFileType(object.type);
	const ctime = finiteNumber(object.ctime);
	const mtime = finiteNumber(object.mtime);
	const size = finiteNumber(object.size);
	const permissions = finiteNumber(object.permissions);

	if (type === undefined || ctime === undefined || mtime === undefined || size === undefined) {
		throw vscode.FileSystemError.Unavailable(vscode.l10n.t("The native file service returned invalid file metadata."));
	}

	if (permissions === undefined) {
		return { type, ctime, mtime, size };
	}
	return { type, ctime, mtime, size, permissions: permissions as vscode.FilePermission };
}

function parseDirectoryEntries(value: JsonValue): [string, vscode.FileType][] {
	const object = asJsonObject(value);
	const entries = object?.entries ?? value;
	if (!Array.isArray(entries)) {
		throw vscode.FileSystemError.Unavailable(
			vscode.l10n.t("The native file service returned an invalid directory listing."),
		);
	}

	return entries.map((entry): [string, vscode.FileType] => {
		let name: JsonValue | undefined;
		let typeValue: JsonValue | undefined;

		if (Array.isArray(entry)) {
			[name, typeValue] = entry;
		} else {
			const entryObject = asJsonObject(entry);
			name = entryObject?.name;
			typeValue = entryObject?.type;
		}

		const type = parseFileType(typeValue);
		if (typeof name !== 'string' || type === undefined) {
			throw vscode.FileSystemError.Unavailable(
				vscode.l10n.t("The native file service returned an invalid directory listing."),
			);
		}

		return [name, type];
	});
}

function parseFileType(value: JsonValue | undefined): vscode.FileType | undefined {
	if (typeof value === 'number' && Number.isInteger(value) && value >= 0) {
		return value as vscode.FileType;
	}

	if (typeof value !== 'string') {
		return undefined;
	}

	if (/^\d+$/.test(value)) {
		return Number(value) as vscode.FileType;
	}

	switch (value.toLowerCase().replace(/[^a-z]/g, '')) {
		case 'unknown': return vscode.FileType.Unknown;
		case 'file': return vscode.FileType.File;
		case 'directory':
		case 'dir':
		case 'folder': return vscode.FileType.Directory;
		case 'symboliclink':
		case 'symlink':
		case 'link': return vscode.FileType.SymbolicLink;
		case 'filesymboliclink':
		case 'symboliclinkfile': return vscode.FileType.File | vscode.FileType.SymbolicLink;
		case 'directorysymboliclink':
		case 'symboliclinkdirectory': return vscode.FileType.Directory | vscode.FileType.SymbolicLink;
		default: return undefined;
	}
}

async function readRevision(response: Response): Promise<string> {
	const text = (await response.text()).trim();
	if (!text) {
		throw vscode.FileSystemError.Unavailable(vscode.l10n.t("The native file service returned an invalid revision."));
	}

	let value: JsonValue = text;
	try {
		value = JSON.parse(text) as JsonValue;
	} catch {
		return text;
	}

	const object = asJsonObject(value);
	const revision = object?.revision ?? value;
	if (typeof revision !== 'string' && typeof revision !== 'number') {
		throw vscode.FileSystemError.Unavailable(vscode.l10n.t("The native file service returned an invalid revision."));
	}

	return String(revision);
}

async function fileSystemErrorFromResponse(
	response: Response,
	resource: vscode.Uri | undefined,
): Promise<vscode.FileSystemError> {
	const details = parseErrorDetails((await response.text()).trim());
	const fallbackMessage = vscode.l10n.t("The native file service request failed with HTTP {0}.", response.status);
	const message = details.message || fallbackMessage;
	const normalizedCode = inferNativeErrorCode(details.message) ?? normalizeErrorCode(details.code);

	switch (normalizedCode) {
		case 'filenotfound':
		case 'enoent':
		case 'notfound': return vscode.FileSystemError.FileNotFound(message);
		case 'fileexists':
		case 'eexist':
		case 'exists':
		case 'alreadyexists': return vscode.FileSystemError.FileExists(message);
		case 'filenotadirectory':
		case 'enotdir':
		case 'notdirectory':
		case 'notadirectory': return vscode.FileSystemError.FileNotADirectory(message);
		case 'fileisadirectory':
		case 'eisdir':
		case 'isadirectory': return vscode.FileSystemError.FileIsADirectory(message);
		case 'nopermissions':
		case 'eacces':
		case 'eperm':
		case 'forbidden': return vscode.FileSystemError.NoPermissions(message);
		case 'unavailable':
		case 'ebusy':
		case 'etimedout':
		case 'serviceunavailable': return vscode.FileSystemError.Unavailable(message);
		case 'directorynotempty':
		case 'enotempty':
			// The extension API has no DirectoryNotEmpty factory; keep the precise message
			// on an Unknown FileSystemError instead of misreporting the entry as existing.
			return new vscode.FileSystemError(message);
		case 'einval':
		case 'invalidpath': return new vscode.FileSystemError(message);
	}

	switch (response.status) {
		case 401:
		case 403: return vscode.FileSystemError.NoPermissions(message);
		case 404:
		case 410: return vscode.FileSystemError.FileNotFound(resource ?? message);
		case 409:
		case 412: return vscode.FileSystemError.FileExists(resource ?? message);
		case 423:
		case 429: return vscode.FileSystemError.Unavailable(message);
	}

	if (response.status >= 500) {
		return vscode.FileSystemError.Unavailable(message);
	}

	return new vscode.FileSystemError(message);
}

function normalizeErrorCode(code: string | undefined): string | undefined {
	return code?.toLowerCase().replace(/[^a-z0-9]/g, '');
}

function inferNativeErrorCode(message: string | undefined): string | undefined {
	switch (message) {
		case 'The workspace entry does not exist.': return 'notfound';
		case 'The workspace entry already exists.': return 'alreadyexists';
		case 'The workspace entry is not a directory.': return 'notadirectory';
		case 'The workspace directory is not empty.': return 'directorynotempty';
		case 'The workspace root cannot be changed by this operation.': return 'forbidden';
		case 'The workspace path is invalid.': return 'invalidpath';
		case 'The iVSCode server stopped.': return 'unavailable';
		default: return undefined;
	}
}

function parseErrorDetails(text: string): ErrorDetails {
	if (!text) {
		return { code: undefined, message: undefined };
	}

	let value: JsonValue;
	try {
		value = JSON.parse(text) as JsonValue;
	} catch {
		return { code: undefined, message: text.slice(0, 1000) };
	}

	const object = asJsonObject(value);
	const nestedError = asJsonObject(object?.error);
	const message = stringValue(nestedError?.message)
		?? stringValue(object?.message)
		?? stringValue(object?.error)
		?? (typeof value === 'string' ? value : undefined);
	return {
		code: stringValue(nestedError?.code) ?? stringValue(object?.code) ?? stringValue(object?.error),
		message,
	};
}

function requestBody(content: Uint8Array): ArrayBuffer {
	const contentBuffer = content.buffer;
	if (contentBuffer instanceof ArrayBuffer) {
		if (content.byteOffset === 0 && content.byteLength === contentBuffer.byteLength) {
			return contentBuffer;
		}
		return contentBuffer.slice(content.byteOffset, content.byteOffset + content.byteLength);
	}

	const copyBuffer = new ArrayBuffer(content.byteLength);
	new Uint8Array(copyBuffer).set(content);
	return copyBuffer;
}

function asJsonObject(value: JsonValue | undefined): JsonObject | undefined {
	return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : undefined;
}

function finiteNumber(value: JsonValue | undefined): number | undefined {
	return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function stringValue(value: JsonValue | undefined): string | undefined {
	return typeof value === 'string' ? value : undefined;
}

export function activate(context: vscode.ExtensionContext): void {
	const provider = new CodeMobileFileSystemProvider();
	context.subscriptions.push(provider);
	context.subscriptions.push(vscode.workspace.registerFileSystemProvider(scheme, provider, { isCaseSensitive: false }));
}
