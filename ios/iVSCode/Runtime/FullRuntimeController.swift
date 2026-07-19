/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import Foundation
import QEMUKit

actor FullRuntimeController {
	static var isAvailable: Bool {
		RuntimeArtifacts.isAvailable && IVQemuLauncher.isProcessAvailable
	}

	private let virtualMachine = QEMUVirtualMachine()
	private var launcher: IVQemuLauncher?
	private var pipeInterface: IVPipeInterface?
	private var prepared: RuntimeArtifacts.Prepared?
	private var shutdownRequested = false
	private var shuttingDown = false
	private var shutdownWaiters: [CheckedContinuation<Bool, Never>] = []

	func start(progress: @escaping @Sendable (String) -> Void) async throws -> URL {
		guard launcher == nil, IVQemuLauncher.isProcessAvailable else {
			throw RuntimeError.alreadyRunning
		}
		shutdownRequested = false

		progress("Verifying the bundled ARM64 Linux workspace")
		let prepared = try RuntimeArtifacts.prepare()
		try Task.checkCancellation()

		progress("Creating private QMP and guest-agent channels")
		let interface = IVPipeInterface(sessionDirectory: prepared.sessionDirectory)
		try interface.start()
		let launcher = IVQemuLauncher(
			arguments: arguments(for: prepared, interface: interface),
			environment: ["TMPDIR": prepared.sessionDirectory.path]
		)
		self.prepared = prepared
		self.pipeInterface = interface
		self.launcher = launcher

		do {
			progress("Starting the no-JIT ARM64 Linux engine")
			try await virtualMachine.start(launcher: launcher, interface: interface)
			try checkOperational()
			guard let monitor = await virtualMachine.monitor else {
				throw RuntimeError.monitorUnavailable
			}
			try await monitor.continueBoot()
			try checkOperational()

			progress("Booting the minimal Alpine workspace")
			let guestAgent = try await waitForGuestAgent()
			progress("Starting the on-device VS Code service")
			try await waitForWorkbenchService(using: guestAgent)

			let url = try workbenchURL(for: prepared)
			progress("Verifying the private VS Code origin")
			try await waitForWorkbenchHTTP(at: url)
			return url
		} catch {
			if !shutdownRequested {
				await stopAfterFailure()
			}
			throw error
		}
	}

	func shutdown() async -> Bool {
		shutdownRequested = true
		if shuttingDown {
			return await withCheckedContinuation { continuation in
				shutdownWaiters.append(continuation)
			}
		}
		shuttingDown = true
		let stopped = await performShutdown()
		shuttingDown = false
		let waiters = shutdownWaiters
		shutdownWaiters.removeAll()
		for waiter in waiters {
			waiter.resume(returning: stopped)
		}
		return stopped
	}

	/// Best-effort expiration path. QMP quit is safe; cross-thread QEMU
	/// cancellation is not. A false result must keep this controller alive.
	func emergencyShutdown() async -> Bool {
		shutdownRequested = true
		if launcher?.isRunning != true {
			if !shuttingDown {
				cleanupAfterStop()
			}
			return true
		}
		if let monitor = await virtualMachine.monitor {
			try? await monitor.qemuQuit()
		} else {
			pipeInterface?.disconnect()
		}
		let stopped = await waitForEngineStop(attempts: 10)
		if stopped, !shuttingDown {
			cleanupAfterStop()
		}
		return stopped
	}

	private func performShutdown() async -> Bool {
		if launcher?.isRunning != true {
			cleanupAfterStop()
			return true
		}

		// If startup is still opening QMP, allow the reviewed control channel
		// to become available. QEMUKit cannot force-kill in-process QEMU on iOS.
		for _ in 0..<150 {
			let monitor = await virtualMachine.monitor
			guard launcher?.isRunning == true, monitor == nil else {
				break
			}
			try? await Task.sleep(for: .milliseconds(100))
		}

		if let guestAgent = await virtualMachine.guestAgent {
			_ = try? await guestAgent.guestExec(
				"/usr/local/sbin/ivscode-poweroff",
				argv: nil,
				envp: nil,
				input: nil,
				captureOutput: false
			)
			if await waitForEngineStop(attempts: 150) {
				cleanupAfterStop()
				return true
			}
		}
		if let monitor = await virtualMachine.monitor {
			try? await monitor.qemuPowerDown()
			if await waitForEngineStop(attempts: 80) {
				cleanupAfterStop()
				return true
			}
			try? await monitor.qemuQuit()
			if await waitForEngineStop(attempts: 30) {
				cleanupAfterStop()
				return true
			}
		}

		// Removing a not-yet-opened FIFO makes QEMU's required chardev fail
		// closed. It is the only safe pre-QMP escape available in this pin.
		pipeInterface?.disconnect()
		if await waitForEngineStop(attempts: 30) {
			cleanupAfterStop()
			return true
		}
		return false
	}

	private func stopAfterFailure() async {
		let monitor = await virtualMachine.monitor
		if monitor != nil {
			try? await virtualMachine.stop()
		}
		if !(await waitForEngineStop(attempts: 30)) {
			pipeInterface?.disconnect()
			_ = await waitForEngineStop(attempts: 30)
		}
		if launcher?.isRunning != true {
			cleanupAfterStop()
		}
	}

	private func waitForGuestAgent() async throws -> QEMUGuestAgent {
		for _ in 0..<90 {
			try checkOperational()
			if let guestAgent = await virtualMachine.guestAgent {
				do {
					try await guestAgent.synchronize()
					return guestAgent
				} catch {
					// The QGA chardev is created before OpenRC starts the daemon.
				}
			}
			try await Task.sleep(for: .seconds(1))
		}
		throw RuntimeError.guestAgentTimedOut
	}

	private func waitForWorkbenchService(using guestAgent: QEMUGuestAgent) async throws {
		var lastDetail: String?
		for _ in 0..<90 {
			try checkOperational()
			do {
				let pid = try await guestAgent.guestExec(
					"/sbin/rc-service",
					argv: ["ivscode", "status"],
					envp: nil,
					input: nil,
					captureOutput: true
				)
				for _ in 0..<20 {
					try checkOperational()
					let status = try await guestAgent.guestExecStatus(pid)
					if status.hasExited {
						if status.exitCode == 0 {
							return
						}
						let detailData = status.errData ?? status.outData
						if let detailData, let detail = String(data: detailData, encoding: .utf8) {
							lastDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
						}
						break
					}
					try await Task.sleep(for: .milliseconds(100))
				}
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				lastDetail = error.localizedDescription
			}
			try await Task.sleep(for: .milliseconds(500))
		}
		throw RuntimeError.workbenchUnavailable(lastDetail)
	}

	private func waitForWorkbenchHTTP(at url: URL) async throws {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		configuration.timeoutIntervalForRequest = 2
		let session = URLSession(configuration: configuration)
		defer { session.invalidateAndCancel() }
		var lastStatus: Int?
		for _ in 0..<60 {
			try checkOperational()
			do {
				let (_, response) = try await session.data(from: url)
				if let response = response as? HTTPURLResponse {
					lastStatus = response.statusCode
					if (200..<400).contains(response.statusCode) {
						return
					}
				}
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				// SLIRP can accept the host port before Node begins listening.
			}
			try await Task.sleep(for: .milliseconds(500))
		}
		throw RuntimeError.workbenchHTTPUnavailable(lastStatus)
	}

	private func workbenchURL(for prepared: RuntimeArtifacts.Prepared) throws -> URL {
		var components = URLComponents()
		components.scheme = "http"
		components.host = "127.0.0.1"
		components.port = Int(prepared.hostPort)
		components.path = "/"
		components.queryItems = [URLQueryItem(name: "tkn", value: prepared.token)]
		guard let url = components.url else {
			throw RuntimeError.invalidURL
		}
		return url
	}

	private func checkOperational() throws {
		try Task.checkCancellation()
		if shutdownRequested {
			throw CancellationError()
		}
	}

	private func waitForEngineStop(attempts: Int) async -> Bool {
		for _ in 0..<attempts {
			if launcher?.isRunning != true {
				return true
			}
			try? await Task.sleep(for: .milliseconds(100))
		}
		return launcher?.isRunning != true
	}

	private func cleanupAfterStop() {
		pipeInterface?.disconnect()
		if let sessionDirectory = prepared?.sessionDirectory {
			try? FileManager.default.removeItem(at: sessionDirectory)
		}
		launcher = nil
		pipeInterface = nil
		prepared = nil
	}

	private func arguments(for prepared: RuntimeArtifacts.Prepared, interface: IVPipeInterface) -> [String] {
		[
			"-nodefaults",
			"-name", "iVSCode",
			"-machine", "virt,highmem=off",
			"-cpu", "cortex-a72",
			"-accel", "tcg,thread=multi,tb-size=64",
			"-smp", "2",
			"-m", "512",
			"-display", "none",
			"-serial", "null",
			"-S",
			"-no-reboot",
			"-kernel", prepared.kernel.path,
			"-initrd", prepared.initramfs.path,
			"-append", "console=ttyAMA0 root=/dev/vda rootfstype=ext4 rw rootwait modules=virtio_pci,virtio_blk,virtio_net",
			"-drive", "if=none,id=root,format=raw,file=\(prepared.rootImage.path)",
			"-device", "virtio-blk-pci,drive=root",
			"-drive", "if=none,id=workspace,format=raw,file=\(prepared.workspaceImage.path)",
			"-device", "virtio-blk-pci,drive=workspace",
			"-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(prepared.hostPort)-:8000",
			"-device", "virtio-net-pci,netdev=net0",
			"-device", "virtio-rng-pci",
			"-device", "virtio-serial-pci",
			"-chardev", "pipe,path=\(interface.monitorBaseURL.path),id=org.qemu.monitor.qmp",
			"-mon", "chardev=org.qemu.monitor.qmp,mode=control",
			"-chardev", "pipe,path=\(interface.guestAgentBaseURL.path),id=org.qemu.guest_agent",
			"-device", "virtserialport,chardev=org.qemu.guest_agent,name=org.qemu.guest_agent.0",
			"-fw_cfg", "name=opt/ivscode/token,file=\(prepared.tokenFile.path)"
		]
	}

	enum RuntimeError: LocalizedError {
		case alreadyRunning
		case monitorUnavailable
		case guestAgentTimedOut
		case workbenchUnavailable(String?)
		case workbenchHTTPUnavailable(Int?)
		case invalidURL

		var errorDescription: String? {
			switch self {
			case .alreadyRunning:
				return "The full workspace is already running."
			case .monitorUnavailable:
				return "The private QEMU monitor did not start."
			case .guestAgentTimedOut:
				return "Alpine did not finish booting in time."
			case .workbenchUnavailable(let detail):
				return detail.map { "The on-device VS Code service failed: \($0)" }
					?? "The on-device VS Code service failed to start."
			case .workbenchHTTPUnavailable(let status):
				return status.map { "The private VS Code origin returned HTTP \($0)." }
					?? "The private VS Code origin did not become reachable."
			case .invalidURL:
				return "The private full-workspace URL could not be created."
			}
		}
	}
}
