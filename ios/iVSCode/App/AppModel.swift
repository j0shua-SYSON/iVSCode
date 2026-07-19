/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import Combine
import Foundation

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

	init() {
		start()
	}

	func start() {
		workbenchStarted = false
		phase = .starting("Preparing the on-device workspace")
		server?.stop()
		server = nil

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

	func resumeIfNeeded() {
		if server == nil {
			start()
		}
	}
}
