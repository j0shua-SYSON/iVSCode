/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import Foundation

struct WorkspaceEntry: Codable {
	let type: Int
	let ctime: Int64
	let mtime: Int64
	let size: Int64
}

enum WorkspaceStoreError: Error, LocalizedError {
	case invalidPath
	case notFound
	case alreadyExists
	case notDirectory
	case directoryNotEmpty
	case forbidden

	var errorDescription: String? {
		switch self {
		case .invalidPath:
			return "The workspace path is invalid."
		case .notFound:
			return "The workspace entry does not exist."
		case .alreadyExists:
			return "The workspace entry already exists."
		case .notDirectory:
			return "The workspace entry is not a directory."
		case .directoryNotEmpty:
			return "The workspace directory is not empty."
		case .forbidden:
			return "The workspace root cannot be changed by this operation."
		}
	}
}

final class WorkspaceStore {
	static let schemeRoot = "/workspace"

	private let fileManager: FileManager
	private let root: URL
	private let revisionLock = NSLock()
	private var currentRevision: UInt64 = 1

	init(fileManager: FileManager = .default) throws {
		self.fileManager = fileManager

		let applicationSupport = try fileManager.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		root = applicationSupport
			.appendingPathComponent("iVSCode", isDirectory: true)
			.appendingPathComponent("Workspaces", isDirectory: true)
			.appendingPathComponent("default", isDirectory: true)

		try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
		try seedWorkspaceIfNeeded()
	}

	func revision() -> UInt64 {
		revisionLock.lock()
		defer { revisionLock.unlock() }
		return currentRevision
	}

	func stat(path: String) throws -> WorkspaceEntry {
		let url = try resolve(path)
		guard fileManager.fileExists(atPath: url.path) else {
			throw WorkspaceStoreError.notFound
		}

		let values = try url.resourceValues(forKeys: [
			.isDirectoryKey,
			.creationDateKey,
			.contentModificationDateKey,
			.fileSizeKey
		])

		return WorkspaceEntry(
			type: values.isDirectory == true ? 2 : 1,
			ctime: milliseconds(values.creationDate),
			mtime: milliseconds(values.contentModificationDate),
			size: Int64(values.fileSize ?? 0)
		)
	}

	func readDirectory(path: String) throws -> [[Any]] {
		let directory = try resolve(path)
		var isDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
			throw WorkspaceStoreError.notFound
		}
		guard isDirectory.boolValue else {
			throw WorkspaceStoreError.notDirectory
		}

		return try fileManager.contentsOfDirectory(
			at: directory,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: []
		)
		.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
		.map { child in
			let values = try child.resourceValues(forKeys: [.isDirectoryKey])
			return [child.lastPathComponent, values.isDirectory == true ? 2 : 1]
		}
	}

	func readFile(path: String) throws -> Data {
		let url = try resolve(path)
		var isDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
			throw WorkspaceStoreError.notFound
		}
		guard !isDirectory.boolValue else {
			throw WorkspaceStoreError.notDirectory
		}
		return try Data(contentsOf: url, options: [.mappedIfSafe])
	}

	func writeFile(path: String, data: Data, create: Bool, overwrite: Bool) throws {
		let url = try resolve(path, allowRoot: false)
		let exists = fileManager.fileExists(atPath: url.path)
		if exists && !overwrite {
			throw WorkspaceStoreError.alreadyExists
		}
		if !exists && !create {
			throw WorkspaceStoreError.notFound
		}

		var parentIsDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
			throw WorkspaceStoreError.notDirectory
		}

		try data.write(to: url, options: [.atomic])
		bumpRevision()
	}

	func createDirectory(path: String) throws {
		let url = try resolve(path, allowRoot: false)
		if fileManager.fileExists(atPath: url.path) {
			throw WorkspaceStoreError.alreadyExists
		}
		try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
		bumpRevision()
	}

	func delete(path: String, recursive: Bool) throws {
		let url = try resolve(path, allowRoot: false)
		var isDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
			throw WorkspaceStoreError.notFound
		}
		if isDirectory.boolValue && !recursive {
			let children = try fileManager.contentsOfDirectory(atPath: url.path)
			if !children.isEmpty {
				throw WorkspaceStoreError.directoryNotEmpty
			}
		}
		try fileManager.removeItem(at: url)
		bumpRevision()
	}

	func rename(from oldPath: String, to newPath: String, overwrite: Bool) throws {
		let source = try resolve(oldPath, allowRoot: false)
		let destination = try resolve(newPath, allowRoot: false)
		guard fileManager.fileExists(atPath: source.path) else {
			throw WorkspaceStoreError.notFound
		}
		if isSameLocation(source, destination) {
			return
		}
		try prepareDestination(destination, overwrite: overwrite)
		try fileManager.moveItem(at: source, to: destination)
		bumpRevision()
	}

	func copy(from oldPath: String, to newPath: String, overwrite: Bool) throws {
		let source = try resolve(oldPath, allowRoot: false)
		let destination = try resolve(newPath, allowRoot: false)
		guard fileManager.fileExists(atPath: source.path) else {
			throw WorkspaceStoreError.notFound
		}
		if isSameLocation(source, destination) {
			throw WorkspaceStoreError.alreadyExists
		}
		try prepareDestination(destination, overwrite: overwrite)
		try fileManager.copyItem(at: source, to: destination)
		bumpRevision()
	}

	private func resolve(_ path: String, allowRoot: Bool = true) throws -> URL {
		guard path == Self.schemeRoot || path.hasPrefix("\(Self.schemeRoot)/") else {
			throw WorkspaceStoreError.invalidPath
		}
		if !allowRoot && path == Self.schemeRoot {
			throw WorkspaceStoreError.forbidden
		}

		let suffix = path.dropFirst(Self.schemeRoot.count)
		let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
		guard components.allSatisfy({ component in
			component != "." && component != ".." && !component.contains("\\") && !component.contains("\0")
		}) else {
			throw WorkspaceStoreError.invalidPath
		}

		var candidate = root
		for component in components {
			candidate.appendPathComponent(String(component), isDirectory: false)
			if fileManager.fileExists(atPath: candidate.path) {
				let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
				if values.isSymbolicLink == true {
					throw WorkspaceStoreError.forbidden
				}
			}
		}
		candidate = candidate.standardizedFileURL
		let rootPath = root.standardizedFileURL.path
		guard candidate.path == rootPath || candidate.path.hasPrefix("\(rootPath)/") else {
			throw WorkspaceStoreError.invalidPath
		}

		let resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
		let resolvedCandidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
		guard resolvedCandidatePath == resolvedRootPath || resolvedCandidatePath.hasPrefix("\(resolvedRootPath)/") else {
			throw WorkspaceStoreError.forbidden
		}
		return candidate
	}

	private func isSameLocation(_ first: URL, _ second: URL) -> Bool {
		first.standardizedFileURL.path.compare(
			second.standardizedFileURL.path,
			options: [.caseInsensitive],
			range: nil,
			locale: Locale(identifier: "en_US_POSIX")
		) == .orderedSame
	}

	private func prepareDestination(_ destination: URL, overwrite: Bool) throws {
		if fileManager.fileExists(atPath: destination.path) {
			guard overwrite else {
				throw WorkspaceStoreError.alreadyExists
			}
			try fileManager.removeItem(at: destination)
		}

		var parentIsDirectory: ObjCBool = false
		guard fileManager.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
			throw WorkspaceStoreError.notDirectory
		}
	}

	private func bumpRevision() {
		revisionLock.lock()
		currentRevision &+= 1
		revisionLock.unlock()
	}

	private func milliseconds(_ date: Date?) -> Int64 {
		Int64((date ?? .distantPast).timeIntervalSince1970 * 1_000)
	}

	private func seedWorkspaceIfNeeded() throws {
		guard try fileManager.contentsOfDirectory(atPath: root.path).isEmpty else {
			return
		}

		let welcome = """
		# Welcome to iVSCode

		This workspace lives on your device. Edit this file, create a project, or
		connect the full Linux runtime for terminals, tasks, debuggers, Git, and
		Node-based extensions.
		"""
		try Data(welcome.utf8).write(to: root.appendingPathComponent("README.md"), options: [.atomic])
	}
}
