/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import CryptoKit
import Darwin
import Foundation
import Security

struct RuntimeArtifacts {
	struct Prepared {
		let kernel: URL
		let initramfs: URL
		let rootImage: URL
		let workspaceImage: URL
		let sessionDirectory: URL
		let tokenFile: URL
		let token: String
		let hostPort: UInt16
	}

	private static let requiredGuestMembers = [
		"vmlinuz-virt",
		"initramfs-virt",
		"rootfs.ext4",
		"workspace.ext4",
		"runtime-manifest.json"
	]

	static var isAvailable: Bool {
#if targetEnvironment(simulator)
		return false
#else
		guard guestDirectory != nil else {
			return false
		}
		let engine = Bundle.main.privateFrameworksURL?
			.appendingPathComponent("qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu")
		return engine.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true
#endif
	}

	static func prepare(fileManager: FileManager = .default) throws -> Prepared {
		guard let guest = guestDirectory else {
			throw RuntimeArtifactError.missingBundle
		}

		let checksums = try parseChecksums(at: guest.appendingPathComponent("SHA256SUMS"))
		for member in requiredGuestMembers {
			let url = guest.appendingPathComponent(member, isDirectory: false)
			guard fileManager.fileExists(atPath: url.path), let expected = checksums[member] else {
				throw RuntimeArtifactError.missingMember(member)
			}
			guard try sha256(of: url) == expected else {
				throw RuntimeArtifactError.checksumMismatch(member)
			}
		}

		let applicationSupport = try fileManager.url(
			for: .applicationSupportDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		)
		let runtimeRoot = applicationSupport
			.appendingPathComponent("iVSCode", isDirectory: true)
			.appendingPathComponent("Runtime", isDirectory: true)
		try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
		try fileManager.setAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: runtimeRoot.path
		)

		let rootImage = runtimeRoot.appendingPathComponent("rootfs.ext4", isDirectory: false)
		let rootMarker = runtimeRoot.appendingPathComponent("rootfs.sha256", isDirectory: false)
		let expectedRoot = checksums["rootfs.ext4"]!
		let installedRoot = try? String(contentsOf: rootMarker, encoding: .utf8)
		if !fileManager.fileExists(atPath: rootImage.path) ||
			installedRoot?.trimmingCharacters(in: .whitespacesAndNewlines) != expectedRoot {
			try replaceCopy(from: guest.appendingPathComponent("rootfs.ext4"), to: rootImage, fileManager: fileManager)
			try Data((expectedRoot + "\n").utf8).write(to: rootMarker, options: .atomic)
		}

		let workspaceImage = runtimeRoot.appendingPathComponent("workspace.ext4", isDirectory: false)
		try installOrRepairWorkspace(
			seed: guest.appendingPathComponent("workspace.ext4"),
			destination: workspaceImage,
			minimumSize: 2 * 1024 * 1024 * 1024,
			fileManager: fileManager
		)

		let sessions = runtimeRoot.appendingPathComponent("Sessions", isDirectory: true)
		if fileManager.fileExists(atPath: sessions.path) {
			try fileManager.removeItem(at: sessions)
		}
		let session = sessions.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
		guard chmod(session.path, S_IRWXU) == 0 else {
			throw RuntimeArtifactError.permissions(errno)
		}

		let token = try makeToken()
		let tokenFile = session.appendingPathComponent("connection-token", isDirectory: false)
		try Data(token.utf8).write(to: tokenFile, options: [.atomic, .completeFileProtection])
		guard chmod(tokenFile.path, S_IRUSR | S_IWUSR) == 0 else {
			throw RuntimeArtifactError.permissions(errno)
		}

		return Prepared(
			kernel: guest.appendingPathComponent("vmlinuz-virt"),
			initramfs: guest.appendingPathComponent("initramfs-virt"),
			rootImage: rootImage,
			workspaceImage: workspaceImage,
			sessionDirectory: session,
			tokenFile: tokenFile,
			token: token,
			hostPort: try selectLoopbackPort()
		)
	}

	private static var guestDirectory: URL? {
		guard let directory = Bundle.main.url(forResource: "Guest", withExtension: nil) else {
			return nil
		}
		return requiredGuestMembers.allSatisfy {
			FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
		} ? directory : nil
	}

	private static func replaceCopy(from source: URL, to destination: URL, fileManager: FileManager) throws {
		let temporary = destination.appendingPathExtension("partial")
		if fileManager.fileExists(atPath: temporary.path) {
			try fileManager.removeItem(at: temporary)
		}
		try fileManager.copyItem(at: source, to: temporary)
		try fileManager.setAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: temporary.path
		)
		if fileManager.fileExists(atPath: destination.path) {
			try fileManager.replaceItemAt(
				destination,
				withItemAt: temporary,
				backupItemName: nil,
				options: .usingNewMetadataOnly
			)
		} else {
			try fileManager.moveItem(at: temporary, to: destination)
		}
	}

	private static func installOrRepairWorkspace(
		seed: URL,
		destination: URL,
		minimumSize: UInt64,
		fileManager: FileManager
	) throws {
		let existingAttributes = try? fileManager.attributesOfItem(atPath: destination.path)
		let existingSize = (existingAttributes?[.size] as? NSNumber)?.uint64Value ?? 0
		if existingSize >= minimumSize {
			return
		}

		let temporary = destination.appendingPathExtension("partial")
		if fileManager.fileExists(atPath: temporary.path) {
			try fileManager.removeItem(at: temporary)
		}
		let source = fileManager.fileExists(atPath: destination.path) ? destination : seed
		try fileManager.copyItem(at: source, to: temporary)
		var installed = false
		defer {
			if !installed {
				try? fileManager.removeItem(at: temporary)
			}
		}

		let workspace = try FileHandle(forWritingTo: temporary)
		do {
			try workspace.truncate(atOffset: minimumSize)
			try workspace.synchronize()
			try workspace.close()
		} catch {
			try? workspace.close()
			throw error
		}
		let resizedAttributes = try fileManager.attributesOfItem(atPath: temporary.path)
		guard let resizedSize = resizedAttributes[.size] as? NSNumber,
			resizedSize.uint64Value == minimumSize else {
			throw RuntimeArtifactError.workspaceResize
		}
		try fileManager.setAttributes(
			[.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
			ofItemAtPath: temporary.path
		)
		if fileManager.fileExists(atPath: destination.path) {
			try fileManager.replaceItemAt(
				destination,
				withItemAt: temporary,
				backupItemName: nil,
				options: .usingNewMetadataOnly
			)
		} else {
			try fileManager.moveItem(at: temporary, to: destination)
		}
		installed = true
	}

	private static func parseChecksums(at url: URL) throws -> [String: String] {
		let contents = try String(contentsOf: url, encoding: .utf8)
		var result: [String: String] = [:]
		for line in contents.split(whereSeparator: \.isNewline) {
			let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
			guard fields.count == 2 else {
				throw RuntimeArtifactError.invalidChecksums
			}
			let hash = String(fields[0]).lowercased()
			var name = String(fields[1]).trimmingCharacters(in: .whitespaces)
			if name.hasPrefix("*") {
				name.removeFirst()
			}
			if name.hasPrefix("./") {
				name.removeFirst(2)
			}
			guard hash.count == 64,
				hash.allSatisfy(\.isHexDigit),
				!name.isEmpty,
				!name.contains("/"),
				result[name] == nil else {
				throw RuntimeArtifactError.invalidChecksums
			}
			result[name] = hash
		}
		return result
	}

	private static func sha256(of url: URL) throws -> String {
		let file = try FileHandle(forReadingFrom: url)
		defer { try? file.close() }
		var hash = SHA256()
		while let data = try file.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
			hash.update(data: data)
		}
		return hash.finalize().map { String(format: "%02x", $0) }.joined()
	}

	private static func makeToken() throws -> String {
		var bytes = [UInt8](repeating: 0, count: 32)
		guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
			throw RuntimeArtifactError.randomness
		}
		return Data(bytes).base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}

	private static func selectLoopbackPort() throws -> UInt16 {
		let descriptor = socket(AF_INET, SOCK_STREAM, 0)
		guard descriptor >= 0 else {
			throw RuntimeArtifactError.port(errno)
		}
		defer { close(descriptor) }

		var address = sockaddr_in()
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_port = 0
		address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
		let bindResult = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		guard bindResult == 0 else {
			throw RuntimeArtifactError.port(errno)
		}

		var length = socklen_t(MemoryLayout<sockaddr_in>.size)
		let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				getsockname(descriptor, $0, &length)
			}
		}
		guard nameResult == 0 else {
			throw RuntimeArtifactError.port(errno)
		}
		return UInt16(bigEndian: address.sin_port)
	}

	enum RuntimeArtifactError: LocalizedError {
		case missingBundle
		case missingMember(String)
		case invalidChecksums
		case checksumMismatch(String)
		case randomness
		case workspaceResize
		case permissions(Int32)
		case port(Int32)

		var errorDescription: String? {
			switch self {
			case .missingBundle:
				return "The bundled Linux runtime is incomplete."
			case .missingMember(let name):
				return "The Linux runtime is missing \(name)."
			case .invalidChecksums:
				return "The Linux runtime checksum manifest is invalid."
			case .checksumMismatch(let name):
				return "The Linux runtime failed verification at \(name)."
			case .randomness:
				return "A private runtime token could not be generated."
			case .workspaceResize:
				return "The persistent Linux workspace could not be initialized safely."
			case .permissions(let code):
				return "The private runtime files could not be protected (errno \(code))."
			case .port(let code):
				return "A private runtime port could not be reserved (errno \(code))."
			}
		}
	}
}
