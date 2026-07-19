/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import Darwin
import Foundation
import QEMUKit

final class IVPipeInterface: NSObject, QEMUInterface {
	weak var connectDelegate: QEMUInterfaceConnectDelegate?

	let monitorBaseURL: URL
	let guestAgentBaseURL: URL

	private let monitorOutURL: URL
	private let monitorInURL: URL
	private let guestAgentOutURL: URL
	private let guestAgentInURL: URL
	private let pipeQueue = DispatchQueue(label: "dev.ivscode.qemu.pipes", qos: .userInitiated)
	private var monitorPort: Port?
	private var guestAgentPort: Port?

	init(sessionDirectory: URL) {
		monitorBaseURL = sessionDirectory.appendingPathComponent("qmp", isDirectory: false)
		guestAgentBaseURL = sessionDirectory.appendingPathComponent("qga", isDirectory: false)
		monitorOutURL = monitorBaseURL.appendingPathExtension("out")
		monitorInURL = monitorBaseURL.appendingPathExtension("in")
		guestAgentOutURL = guestAgentBaseURL.appendingPathExtension("out")
		guestAgentInURL = guestAgentBaseURL.appendingPathExtension("in")
	}

	func start() throws {
		try createFIFO(at: monitorOutURL)
		try createFIFO(at: monitorInURL)
		try createFIFO(at: guestAgentOutURL)
		try createFIFO(at: guestAgentInURL)
	}

	func connect() throws {
		pipeQueue.async { [weak self] in
			guard let self else {
				return
			}
			do {
				try self.openPipes()
				guard let monitorPort = self.monitorPort, let guestAgentPort = self.guestAgentPort else {
					throw PipeError.connectionFailed
				}
				self.connectDelegate?.qemuInterface(self, didCreateMonitorPort: monitorPort)
				self.connectDelegate?.qemuInterface(self, didCreateGuestAgentPort: guestAgentPort)
			} catch {
				self.connectDelegate?.qemuInterface(self, didErrorWithMessage: error.localizedDescription)
			}
		}
	}

	func disconnect() {
		for url in [monitorOutURL, monitorInURL, guestAgentOutURL, guestAgentInURL] {
			_ = try? FileHandle(forUpdating: url).close()
		}
		pipeQueue.sync {
			monitorPort?.close()
			guestAgentPort?.close()
			monitorPort = nil
			guestAgentPort = nil
			for url in [monitorOutURL, monitorInURL, guestAgentOutURL, guestAgentInURL] {
				try? FileManager.default.removeItem(at: url)
			}
		}
	}

	private func createFIFO(at url: URL) throws {
		if FileManager.default.fileExists(atPath: url.path) {
			try FileManager.default.removeItem(at: url)
		}
		guard mkfifo(url.path, S_IRUSR | S_IWUSR) == 0 else {
			throw PipeError.createFailed(errno)
		}
	}

	private func openPipes() throws {
		let monitorRead = try FileHandle(forReadingFrom: monitorOutURL)
		let monitorWrite = try FileHandle(forWritingTo: monitorInURL)
		monitorPort = Port(read: monitorRead, write: monitorWrite)

		let guestRead = try FileHandle(forReadingFrom: guestAgentOutURL)
		let guestWrite = try FileHandle(forWritingTo: guestAgentInURL)
		guestAgentPort = Port(read: guestRead, write: guestWrite)
	}

	final class Port: NSObject, QEMUPort {
		var readDataHandler: readDataHandler_t?
		var errorHandler: errorHandler_t?
		var disconnectHandler: disconnectHandler_t?
		private(set) var isOpen = true

		private let readHandle: FileHandle
		private let writeHandle: FileHandle

		init(read: FileHandle, write: FileHandle) {
			readHandle = read
			writeHandle = write
			super.init()
			readHandle.readabilityHandler = { [weak self] handle in
				guard let self else {
					return
				}
				let data = handle.availableData
				if data.isEmpty {
					self.isOpen = false
					self.disconnectHandler?()
				} else {
					self.readDataHandler?(data)
				}
			}
		}

		func write(_ data: Data) {
			do {
				try writeHandle.write(contentsOf: data)
			} catch {
				errorHandler?(error.localizedDescription)
			}
		}

		func close() {
			guard isOpen else {
				return
			}
			isOpen = false
			readHandle.readabilityHandler = nil
			try? readHandle.close()
			try? writeHandle.close()
		}
	}

	enum PipeError: LocalizedError {
		case createFailed(Int32)
		case connectionFailed

		var errorDescription: String? {
			switch self {
			case .createFailed(let code):
				return "The private QEMU control pipe could not be created (errno \(code))."
			case .connectionFailed:
				return "The private QEMU control pipes could not be opened."
			}
		}
	}
}
