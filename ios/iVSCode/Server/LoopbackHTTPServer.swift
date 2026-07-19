/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import Foundation
import Network

enum LoopbackServerError: Error, LocalizedError {
	case missingWorkbench
	case listenerFailed(String)

	var errorDescription: String? {
		switch self {
		case .missingWorkbench:
			return "The packaged iVSCode workbench is missing."
		case .listenerFailed(let message):
			return "The local workbench server failed: \(message)"
		}
	}
}

private struct HTTPRequest {
	let method: String
	let target: String
	let headers: [String: String]
	let body: Data

	var components: URLComponents? {
		URLComponents(string: "http://127.0.0.1\(target)")
	}

	var path: String {
		components?.percentEncodedPath.removingPercentEncoding ?? "/"
	}

	func query(_ name: String) -> String? {
		components?.queryItems?.first(where: { $0.name == name })?.value
	}
}

private struct HTTPResponse {
	let status: Int
	let reason: String
	var headers: [String: String]
	let body: Data
	let reportedContentLength: Int?

	init(
		status: Int = 200,
		reason: String = "OK",
		headers: [String: String] = [:],
		body: Data = Data(),
		reportedContentLength: Int? = nil
	) {
		self.status = status
		self.reason = reason
		self.headers = headers
		self.body = body
		self.reportedContentLength = reportedContentLength
	}

	static func json(_ object: Any, status: Int = 200, reason: String = "OK") throws -> HTTPResponse {
		HTTPResponse(
			status: status,
			reason: reason,
			headers: ["Content-Type": "application/json; charset=utf-8"],
			body: try JSONSerialization.data(withJSONObject: object)
		)
	}

	static func error(_ status: Int, _ reason: String, _ message: String, code: String = "Unknown") -> HTTPResponse {
		(try? json(["error": ["code": code, "message": message]], status: status, reason: reason))
			?? HTTPResponse(status: status, reason: reason, body: Data(message.utf8))
	}
}

final class LoopbackHTTPServer {
	private static let maximumRequestBytes = 32 * 1_024 * 1_024

	private let queue = DispatchQueue(label: "dev.ivscode.loopback-server", qos: .userInitiated)
	private let workbenchRoot: URL
	private let workspaceStore: WorkspaceStore
	private let sessionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

	private var listener: NWListener?
	private var serverURL: URL?
	private var startCallbacks: [(Result<URL, Error>) -> Void] = []
	private var connections: [UUID: HTTPConnection] = [:]
	var failureHandler: ((Error) -> Void)?

	init(bundle: Bundle = .main) throws {
		guard let workbenchRoot = bundle.url(forResource: "Workbench", withExtension: nil) else {
			throw LoopbackServerError.missingWorkbench
		}
		self.workbenchRoot = workbenchRoot
		workspaceStore = try WorkspaceStore()
	}

	func start(completion: @escaping (Result<URL, Error>) -> Void) {
		queue.async { [weak self] in
			guard let self else {
				return
			}
			if let serverURL = self.serverURL {
				completion(.success(serverURL))
				return
			}

			self.startCallbacks.append(completion)
			guard self.listener == nil else {
				return
			}

			do {
				let parameters = NWParameters.tcp
				parameters.allowLocalEndpointReuse = true
				parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
				let listener = try NWListener(using: parameters)
				self.listener = listener

				listener.stateUpdateHandler = { [weak self] state in
					self?.handleListenerState(state)
				}
				listener.newConnectionHandler = { [weak self] connection in
					self?.accept(connection)
				}
				listener.start(queue: self.queue)
			} catch {
				self.finishStart(.failure(error))
			}
		}
	}

	func stop() {
		queue.async { [self] in
			listener?.cancel()
			listener = nil
			serverURL = nil
			let activeConnections = Array(connections.values)
			connections.removeAll()
			activeConnections.forEach { $0.cancel() }
		}
	}

	private func handleListenerState(_ state: NWListener.State) {
		switch state {
		case .ready:
			guard let port = listener?.port,
				let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
				finishStart(.failure(LoopbackServerError.listenerFailed("no loopback port was assigned")))
				return
			}
			serverURL = url
			finishStart(.success(url))
		case .failed(let error):
			let failure = LoopbackServerError.listenerFailed(error.localizedDescription)
			let wasReady = serverURL != nil
			serverURL = nil
			finishStart(.failure(failure))
			if wasReady {
				failureHandler?(failure)
			}
			listener?.cancel()
			listener = nil
		case .cancelled:
			serverURL = nil
		default:
			break
		}
	}

	private func finishStart(_ result: Result<URL, Error>) {
		let callbacks = startCallbacks
		startCallbacks.removeAll()
		callbacks.forEach { $0(result) }
	}

	private func accept(_ connection: NWConnection) {
		let identifier = UUID()
		let handler = HTTPConnection(
			connection: connection,
			queue: queue,
			maximumRequestBytes: Self.maximumRequestBytes,
			route: { [weak self] request in
				self?.route(request) ?? .error(503, "Service Unavailable", "The iVSCode server stopped.")
			},
			onClose: { [weak self] in
				self?.connections.removeValue(forKey: identifier)
			}
		)
		connections[identifier] = handler
		handler.start()
	}

	private func route(_ request: HTTPRequest) -> HTTPResponse {
		do {
			if request.path.hasPrefix("/__code_mobile__/fs") {
				guard isAuthorized(request) else {
					return .error(403, "Forbidden", "The workspace session is not authorized.", code: "NoPermissions")
				}
				return try routeWorkspace(request)
			}
			return try routeStatic(request)
		} catch let error as WorkspaceStoreError {
			return workspaceError(error)
		} catch is DecodingError {
			return .error(400, "Bad Request", "The workspace operation payload is invalid.", code: "InvalidRequest")
		} catch {
			return .error(500, "Internal Server Error", error.localizedDescription)
		}
	}

	private func routeWorkspace(_ request: HTTPRequest) throws -> HTTPResponse {
		let route = String(request.path.dropFirst("/__code_mobile__/fs".count))
		let path = request.query("path") ?? WorkspaceStore.schemeRoot

		switch (request.method, route) {
		case ("GET", "/stat"):
			let entry = try workspaceStore.stat(path: path)
			return try .json([
				"type": entry.type,
				"ctime": entry.ctime,
				"mtime": entry.mtime,
				"size": entry.size
			])

		case ("GET", "/read-directory"):
			return try .json(try workspaceStore.readDirectory(path: path))

		case ("GET", "/read-file"):
			return HTTPResponse(
				headers: ["Content-Type": "application/octet-stream", "Cache-Control": "no-store"],
				body: try workspaceStore.readFile(path: path)
			)

		case ("PUT", "/write-file"):
			guard request.headers["content-length"] != nil else {
				return .error(411, "Length Required", "Workspace writes require an explicit Content-Length.")
			}
			try workspaceStore.writeFile(
				path: path,
				data: request.body,
				create: request.query("create") == "true",
				overwrite: request.query("overwrite") == "true"
			)
			return HTTPResponse(status: 204, reason: "No Content")

		case ("POST", "/create-directory"):
			try workspaceStore.createDirectory(path: path)
			return HTTPResponse(status: 204, reason: "No Content")

		case ("DELETE", "/entry"):
			try workspaceStore.delete(path: path, recursive: request.query("recursive") == "true")
			return HTTPResponse(status: 204, reason: "No Content")

		case ("POST", "/rename"):
			guard request.headers["content-length"] != nil else {
				return .error(411, "Length Required", "Workspace rename requests require an explicit Content-Length.")
			}
			let operation = try JSONDecoder().decode(WorkspaceTransfer.self, from: request.body)
			try workspaceStore.rename(from: operation.oldPath, to: operation.newPath, overwrite: operation.overwrite)
			return HTTPResponse(status: 204, reason: "No Content")

		case ("POST", "/copy"):
			guard request.headers["content-length"] != nil else {
				return .error(411, "Length Required", "Workspace copy requests require an explicit Content-Length.")
			}
			let operation = try JSONDecoder().decode(WorkspaceTransfer.self, from: request.body)
			try workspaceStore.copy(from: operation.oldPath, to: operation.newPath, overwrite: operation.overwrite)
			return HTTPResponse(status: 204, reason: "No Content")

		case ("GET", "/revision"):
			return try .json(["revision": workspaceStore.revision()])

		default:
			return .error(404, "Not Found", "Unknown workspace endpoint.")
		}
	}

	private func routeStatic(_ request: HTTPRequest) throws -> HTTPResponse {
		guard request.method == "GET" || request.method == "HEAD" else {
			return .error(405, "Method Not Allowed", "Only GET and HEAD are supported for app resources.")
		}

		let requestPath = request.path == "/" ? "/index.html" : request.path
		let components = requestPath.split(separator: "/", omittingEmptySubsequences: true)
		guard components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
			return .error(400, "Bad Request", "The resource path is invalid.")
		}

		let resource = components.reduce(workbenchRoot) { partial, component in
			partial.appendingPathComponent(String(component), isDirectory: false)
		}.standardizedFileURL
		let rootPath = workbenchRoot.standardizedFileURL.path
		guard resource.path.hasPrefix("\(rootPath)/") else {
			return .error(403, "Forbidden", "The resource is outside the app bundle.")
		}

		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: resource.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
			return .error(404, "Not Found", "The packaged workbench resource was not found.")
		}

		let completeBody = try Data(contentsOf: resource, options: [.mappedIfSafe])
		var body = completeBody
		var status = 200
		var reason = "OK"
		var headers = [
			"Content-Type": mimeType(for: resource.pathExtension),
			"Cache-Control": requestPath == "/index.html" ? "no-cache" : "public, max-age=31536000, immutable",
			"X-Content-Type-Options": "nosniff",
			"Referrer-Policy": "no-referrer"
		]

		if requestPath == "/index.html" {
			headers["Set-Cookie"] = "ivscode_session=\(sessionToken); HttpOnly; SameSite=Strict; Path=/"
		}

		if let range = request.headers["range"],
			let bounds = byteRange(range, count: completeBody.count) {
			status = 206
			reason = "Partial Content"
			body = completeBody.subdata(in: bounds)
			headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(completeBody.count)"
			headers["Accept-Ranges"] = "bytes"
		}

		let reportedContentLength = body.count
		if request.method == "HEAD" {
			body = Data()
		}
		return HTTPResponse(
			status: status,
			reason: reason,
			headers: headers,
			body: body,
			reportedContentLength: reportedContentLength
		)
	}

	private func isAuthorized(_ request: HTTPRequest) -> Bool {
		request.headers["cookie"]?
			.split(separator: ";")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.contains("ivscode_session=\(sessionToken)") == true
	}

	private func workspaceError(_ error: WorkspaceStoreError) -> HTTPResponse {
		switch error {
		case .notFound:
			return .error(404, "Not Found", error.localizedDescription, code: "FileNotFound")
		case .alreadyExists:
			return .error(409, "Conflict", error.localizedDescription, code: "FileExists")
		case .directoryNotEmpty:
			return .error(409, "Conflict", error.localizedDescription, code: "DirectoryNotEmpty")
		case .forbidden:
			return .error(403, "Forbidden", error.localizedDescription, code: "NoPermissions")
		case .invalidPath:
			return .error(400, "Bad Request", error.localizedDescription, code: "InvalidPath")
		case .notDirectory:
			return .error(400, "Bad Request", error.localizedDescription, code: "FileNotADirectory")
		}
	}

	private func byteRange(_ value: String, count: Int) -> Range<Int>? {
		guard value.hasPrefix("bytes="), count > 0 else {
			return nil
		}
		let values = value.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
		guard values.count == 2,
			let start = Int(values[0]),
			start >= 0,
			start < count else {
			return nil
		}
		let requestedEnd = values[1].isEmpty ? count - 1 : Int(values[1]) ?? count - 1
		let end = min(max(requestedEnd, start), count - 1)
		return start..<(end + 1)
	}

	private func mimeType(for pathExtension: String) -> String {
		switch pathExtension.lowercased() {
		case "html": return "text/html; charset=utf-8"
		case "js", "mjs": return "text/javascript; charset=utf-8"
		case "css": return "text/css; charset=utf-8"
		case "json", "map": return "application/json; charset=utf-8"
		case "wasm": return "application/wasm"
		case "svg": return "image/svg+xml"
		case "png": return "image/png"
		case "jpg", "jpeg": return "image/jpeg"
		case "gif": return "image/gif"
		case "ico": return "image/x-icon"
		case "woff": return "font/woff"
		case "woff2": return "font/woff2"
		case "ttf": return "font/ttf"
		case "mp3": return "audio/mpeg"
		default: return "application/octet-stream"
		}
	}
}

private struct WorkspaceTransfer: Decodable {
	let oldPath: String
	let newPath: String
	let overwrite: Bool
}

private enum HTTPConnectionError: Error, LocalizedError, Equatable {
	case headerTooLarge
	case invalidContentLength
	case duplicateContentLength
	case unsupportedTransferEncoding
	case requestTooLarge

	var errorDescription: String? {
		switch self {
		case .headerTooLarge:
			return "The HTTP header exceeds the local server limit."
		case .invalidContentLength:
			return "The HTTP Content-Length is invalid."
		case .duplicateContentLength:
			return "Duplicate HTTP Content-Length headers are not supported."
		case .unsupportedTransferEncoding:
			return "HTTP transfer encoding is not supported by the local server."
		case .requestTooLarge:
			return "The request exceeds the workspace transfer limit."
		}
	}
}

private final class HTTPConnection {
	private static let headerTerminator = Data("\r\n\r\n".utf8)
	private static let maximumHeaderBytes = 64 * 1_024

	private let connection: NWConnection
	private let queue: DispatchQueue
	private let maximumRequestBytes: Int
	private let route: (HTTPRequest) -> HTTPResponse
	private let onClose: () -> Void

	private var buffer = Data()
	private var expectedRequestBytes: Int?
	private var didFinish = false

	init(
		connection: NWConnection,
		queue: DispatchQueue,
		maximumRequestBytes: Int,
		route: @escaping (HTTPRequest) -> HTTPResponse,
		onClose: @escaping () -> Void
	) {
		self.connection = connection
		self.queue = queue
		self.maximumRequestBytes = maximumRequestBytes
		self.route = route
		self.onClose = onClose
	}

	func start() {
		connection.stateUpdateHandler = { [weak self] state in
			if case .failed = state {
				self?.finish()
			} else if case .cancelled = state {
				self?.finish()
			}
		}
		connection.start(queue: queue)
		receive()
	}

	func cancel() {
		connection.cancel()
		finish()
	}

	private func receive() {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024 * 1_024) { [weak self] data, _, isComplete, error in
			guard let self, !self.didFinish else {
				return
			}
			if let data {
				self.buffer.append(data)
			}
			if self.buffer.count > self.maximumRequestBytes {
				self.send(.error(413, "Content Too Large", HTTPConnectionError.requestTooLarge.localizedDescription))
				return
			}

			if self.expectedRequestBytes == nil {
				if let headerRange = self.buffer.range(of: Self.headerTerminator) {
					do {
						guard headerRange.upperBound <= Self.maximumHeaderBytes else {
							throw HTTPConnectionError.headerTooLarge
						}
						let header = self.buffer[..<headerRange.lowerBound]
						let contentLength = try self.contentLength(in: header)
						let (expectedRequestBytes, overflow) = headerRange.upperBound.addingReportingOverflow(contentLength)
						guard !overflow, expectedRequestBytes <= self.maximumRequestBytes else {
							throw HTTPConnectionError.requestTooLarge
						}
						self.expectedRequestBytes = expectedRequestBytes
					} catch let error as HTTPConnectionError {
						let status = error == .headerTooLarge ? 431 : (error == .requestTooLarge ? 413 : 400)
						let reason = status == 431 ? "Request Header Fields Too Large" : (status == 413 ? "Content Too Large" : "Bad Request")
						self.send(.error(status, reason, error.localizedDescription))
						return
					} catch {
						self.send(.error(400, "Bad Request", error.localizedDescription))
						return
					}
				} else if self.buffer.count > Self.maximumHeaderBytes {
					self.send(.error(431, "Request Header Fields Too Large", HTTPConnectionError.headerTooLarge.localizedDescription))
					return
				}
			}

			if let expectedRequestBytes = self.expectedRequestBytes,
				self.buffer.count >= expectedRequestBytes {
				do {
					let request = try self.parseRequest(Data(self.buffer.prefix(expectedRequestBytes)))
					self.send(self.route(request), headOnly: request.method == "HEAD")
				} catch {
					self.send(.error(400, "Bad Request", error.localizedDescription))
				}
				return
			}

			if error != nil || isComplete {
				self.finish()
			} else {
				self.receive()
			}
		}
	}

	private func parseRequest(_ data: Data) throws -> HTTPRequest {
		guard let headerRange = data.range(of: Self.headerTerminator),
			let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
			throw LoopbackServerError.listenerFailed("invalid HTTP header")
		}
		let lines = headerText.components(separatedBy: "\r\n")
		guard let requestLine = lines.first else {
			throw LoopbackServerError.listenerFailed("missing HTTP request line")
		}
		let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
		guard requestParts.count >= 2 else {
			throw LoopbackServerError.listenerFailed("invalid HTTP request line")
		}

		var headers: [String: String] = [:]
		for line in lines.dropFirst() {
			guard let separator = line.firstIndex(of: ":") else {
				continue
			}
			let name = line[..<separator].lowercased()
			let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
			headers[name] = value
		}

		return HTTPRequest(
			method: String(requestParts[0]).uppercased(),
			target: String(requestParts[1]),
			headers: headers,
			body: Data(data[headerRange.upperBound...])
		)
	}

	private func contentLength(in header: Data.SubSequence) throws -> Int {
		guard let headerText = String(data: header, encoding: .utf8) else {
			throw HTTPConnectionError.invalidContentLength
		}
		var contentLength: Int?
		for line in headerText.components(separatedBy: "\r\n") {
			let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
			guard parts.count == 2 else {
				continue
			}
			let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
			if name == "transfer-encoding" {
				throw HTTPConnectionError.unsupportedTransferEncoding
			}
			if name == "content-length" {
				guard contentLength == nil else {
					throw HTTPConnectionError.duplicateContentLength
				}
				let value = parts[1].trimmingCharacters(in: .whitespaces)
				guard let parsed = Int(value), parsed >= 0 else {
					throw HTTPConnectionError.invalidContentLength
				}
				contentLength = parsed
			}
		}
		return contentLength ?? 0
	}

	private func send(_ response: HTTPResponse, headOnly: Bool = false) {
		var headers = response.headers
		headers["Content-Length"] = String(response.reportedContentLength ?? response.body.count)
		headers["Connection"] = "close"

		var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
		for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
			head += "\(name): \(value)\r\n"
		}
		head += "\r\n"

		connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
			guard let self, error == nil, !headOnly, !response.body.isEmpty else {
				self?.finish()
				return
			}
			self.connection.send(content: response.body, isComplete: true, completion: .contentProcessed { [weak self] _ in
				self?.finish()
			})
		})
	}

	private func finish() {
		guard !didFinish else {
			return
		}
		didFinish = true
		connection.cancel()
		onClose()
	}
}
