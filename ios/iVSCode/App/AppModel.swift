/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
	enum Phase: Equatable {
		case starting(String)
		case ready(URL)
		case failed(String)
	}

	@Published private(set) var phase: Phase = .starting("Preparing the on-device workspace")
	@Published private(set) var workbenchStarted = false

	private var server: LoopbackHTTPServer?
	private var fullRuntime: FullRuntimeController?
	private var stalledRuntime: FullRuntimeController?
	private var startTask: Task<Void, Never>?
	private var startGeneration = 0
	private var shutdownTask: Task<Void, Never>?
	private var shutdownID: UUID?
	private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

	init() {
		start()
	}

	func start() {
		startGeneration += 1
		let generation = startGeneration
		startTask?.cancel()
		let pendingShutdown = shutdownTask
		let previousRuntime = fullRuntime
		fullRuntime = nil
		workbenchStarted = false
		phase = .starting("Preparing the on-device workspace")
		server?.stop()
		server = nil

		startTask = Task { [weak self] in
			await pendingShutdown?.value
			let previousStopped: Bool
			if let previousRuntime {
				previousStopped = await previousRuntime.shutdown()
			} else {
				previousStopped = true
			}
			guard let self else {
				return
			}
			if !previousStopped, let previousRuntime {
				self.stalledRuntime = previousRuntime
			}
			guard !Task.isCancelled, self.startGeneration == generation else {
				return
			}
			await self.startPreferredWorkspace(generation: generation)
			if self.startGeneration == generation {
				self.startTask = nil
			}
		}
	}

	private func startPreferredWorkspace(generation: Int) async {
		if stalledRuntime == nil, FullRuntimeController.isAvailable {
			let runtime = FullRuntimeController()
			fullRuntime = runtime
			do {
				let url = try await runtime.start { [weak self] message in
					Task { @MainActor in
						guard let self,
							self.startGeneration == generation,
							self.fullRuntime === runtime else {
							return
						}
						self.phase = .starting(message)
					}
				}
				guard startGeneration == generation, fullRuntime === runtime else {
					if !(await runtime.shutdown()) {
						stalledRuntime = runtime
					}
					return
				}
				phase = .ready(url)
				return
			} catch is CancellationError {
				if !(await runtime.shutdown()) {
					stalledRuntime = runtime
				}
				return
			} catch {
				if !(await runtime.shutdown()) {
					stalledRuntime = runtime
				}
				if startGeneration == generation, fullRuntime === runtime {
					fullRuntime = nil
					phase = .starting("Full workspace unavailable; starting instant workspace")
				}
			}
		}

		guard !Task.isCancelled, startGeneration == generation, fullRuntime == nil else {
			return
		}
		if stalledRuntime != nil {
			phase = .starting("Using the instant workspace until iVSCode restarts")
		}
		startInstantWorkspace()
	}

	private func startInstantWorkspace() {

		do {
			let server = try LoopbackHTTPServer()
			self.server = server
			server.failureHandler = { [weak self, weak server] error in
				DispatchQueue.main.async {
					guard let self, let server, self.server === server else {
						return
					}
					server.stop()
					self.server = nil
					self.phase = .failed(error.localizedDescription)
				}
			}
			phase = .starting("Starting the private workbench origin")
			server.start { [weak self, weak server] result in
				DispatchQueue.main.async {
					guard let self, let server, self.server === server else {
						return
					}
					switch result {
					case .success(let url):
						self.phase = .ready(url)
					case .failure(let error):
						self.server = nil
						self.phase = .failed(error.localizedDescription)
					}
				}
			}
		} catch {
			phase = .failed(error.localizedDescription)
		}
	}

	func receiveWorkbenchMessage(_ body: Any) {
		guard let message = body as? [String: Any], message["type"] as? String == "workbenchStarted" else {
			return
		}
		workbenchStarted = true
	}

	func workbenchNavigationFailed(_ message: String) {
		phase = .failed(message)
	}

	func workbenchNavigationFinished() {
		if fullRuntime != nil {
			workbenchStarted = true
		}
	}

	func prepareForBackground() {
		guard let runtime = fullRuntime else {
			return
		}
		startGeneration += 1
		// Let an in-flight QMP connection finish so the interpreter can be
		// stopped safely; pinned QEMUKit has no pre-QMP force-kill on iOS.
		startTask = nil
		fullRuntime = nil
		workbenchStarted = false
		let shutdownID = UUID()
		self.shutdownID = shutdownID
		if backgroundTask == .invalid {
			backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Stop iVSCode Linux") { [weak self] in
				Task {
					let stopped = await runtime.emergencyShutdown()
					await MainActor.run {
						guard let self else {
							return
						}
						if !stopped {
							self.stalledRuntime = runtime
						}
						self.endBackgroundTask()
					}
				}
			}
		}
		shutdownTask = Task { [weak self] in
			let stopped = await runtime.shutdown()
			guard let self else {
				return
			}
			if stopped, self.stalledRuntime === runtime {
				self.stalledRuntime = nil
			} else if !stopped {
				self.stalledRuntime = runtime
			}
			if self.shutdownID == shutdownID {
				self.shutdownTask = nil
				self.shutdownID = nil
			}
			self.endBackgroundTask()
		}
	}

	private func endBackgroundTask() {
		guard backgroundTask != .invalid else {
			return
		}
		UIApplication.shared.endBackgroundTask(backgroundTask)
		backgroundTask = .invalid
	}

	func resumeIfNeeded() {
		if server == nil, fullRuntime == nil, startTask == nil {
			start()
		}
	}
}
