import Foundation
import Network

struct PeerEndpoint: Equatable, Sendable {
    static let defaultPort: UInt16 = 48_621

    let host: String
    let port: UInt16

    static func parse(_ input: String) throws -> PeerEndpoint {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeerProtocolError.invalidAddress }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "http",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/"
        else { throw PeerProtocolError.invalidAddress }
        let portValue = components.port ?? Int(defaultPort)
        guard (1...65_535).contains(portValue) else { throw PeerProtocolError.invalidAddress }
        return PeerEndpoint(host: host, port: UInt16(portValue))
    }

    var hostHeader: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

final class PeerPayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private struct ParsedHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
}

private struct ParsedHTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private enum PeerHTTPCodec {
    static let headerTerminator = Data([13, 10, 13, 10])

    static func request(from data: Data) throws -> ParsedHTTPRequest {
        guard let range = data.range(of: headerTerminator), range.upperBound == data.endIndex,
              let text = String(data: data[..<range.lowerBound], encoding: .utf8)
        else { throw PeerProtocolError.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw PeerProtocolError.invalidRequest }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2] == "HTTP/1.1" else { throw PeerProtocolError.invalidRequest }
        return ParsedHTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: try headers(from: lines.dropFirst())
        )
    }

    static func response(from data: Data) throws -> ParsedHTTPResponse {
        guard let range = data.range(of: headerTerminator),
              let text = String(data: data[..<range.lowerBound], encoding: .utf8)
        else { throw PeerProtocolError.invalidResponse }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw PeerProtocolError.invalidResponse }
        let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "HTTP/1.1", let status = Int(parts[1]) else {
            throw PeerProtocolError.invalidResponse
        }
        let headers = try headers(from: lines.dropFirst())
        let encodedBody = Data(data[range.upperBound...])
        let body: Data
        if let contentLengthText = headers["content-length"], let contentLength = Int(contentLengthText) {
            guard contentLength == encodedBody.count else { throw PeerProtocolError.invalidResponse }
            body = encodedBody
        } else if headers["transfer-encoding"]?.lowercased() == "chunked" {
            body = try decodeChunked(encodedBody)
        } else {
            throw PeerProtocolError.invalidResponse
        }
        return ParsedHTTPResponse(status: status, headers: headers, body: body)
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        let lineEnd = Data([13, 10])
        var cursor = data.startIndex
        var result = Data()
        while cursor < data.endIndex {
            guard let sizeRange = data[cursor...].range(of: lineEnd),
                  let sizeLine = String(data: data[cursor..<sizeRange.lowerBound], encoding: .ascii)
            else { throw PeerProtocolError.invalidResponse }
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                throw PeerProtocolError.invalidResponse
            }
            cursor = sizeRange.upperBound
            if size == 0 {
                guard cursor + 2 <= data.endIndex,
                      data[cursor] == 13, data[cursor + 1] == 10
                else { throw PeerProtocolError.invalidResponse }
                return result
            }
            guard size <= 65_536, result.count + size <= 65_536,
                  cursor + size + 2 <= data.endIndex
            else { throw PeerProtocolError.bodyTooLarge }
            result.append(data[cursor..<(cursor + size)])
            cursor += size
            guard data[cursor] == 13, data[cursor + 1] == 10 else {
                throw PeerProtocolError.invalidResponse
            }
            cursor += 2
        }
        throw PeerProtocolError.invalidResponse
    }

    private static func headers<S: Sequence>(from lines: S) throws -> [String: String] where S.Element == String {
        var result: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw PeerProtocolError.invalidResponse }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, result[name] == nil else { throw PeerProtocolError.invalidResponse }
            result[name] = value
        }
        return result
    }
}

final class PeerHTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.yangyuchen.devicemonitor.peer.server", qos: .utility)
    private let port: UInt16
    private let secret: Data
    private let payloadBox: PeerPayloadBox
    private let stateHandler: @Sendable (String?) -> Void
    private var listener: NWListener?
    private var acceptedNonces: [String: Int64] = [:]
    private var activeRequests: [UUID: PeerServerRequest] = [:]

    init(
        port: UInt16 = PeerEndpoint.defaultPort,
        secret: Data,
        payloadBox: PeerPayloadBox,
        stateHandler: @escaping @Sendable (String?) -> Void
    ) {
        self.port = port
        self.secret = secret
        self.payloadBox = payloadBox
        self.stateHandler = stateHandler
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw PeerProtocolError.invalidAddress }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        // NWListener cancellation is asynchronous. Permit the same process to
        // reclaim the fixed peer port when the feature is toggled or its secret
        // changes without surfacing EADDRINUSE (NWError 48).
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.stateHandler(nil)
            case .failed(let error): self.stateHandler(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.acceptedNonces.removeAll()
            self?.activeRequests.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let request = PeerServerRequest(id: id, connection: connection, queue: queue) { [weak self] id, connection, data in
            guard let self else { return }
            self.activeRequests.removeValue(forKey: id)
            if let data { self.handle(connection: connection, requestData: data) }
        }
        activeRequests[id] = request
        request.start()
    }

    private func handle(connection: NWConnection, requestData: Data) {
        do {
            let request = try PeerHTTPCodec.request(from: requestData)
            guard request.method == "GET", request.path == "/v1/status" else {
                sendError(.invalidRequest, status: 400, connection: connection)
                return
            }
            guard request.headers["x-dm-api-version"] == "1" else {
                sendError(.incompatibleVersion, status: 426, connection: connection)
                return
            }
            guard let deviceID = request.headers["x-dm-device-id"], UUID(uuidString: deviceID) != nil,
                  let timestampText = request.headers["x-dm-timestamp"], let timestamp = Int64(timestampText),
                  let nonce = request.headers["x-dm-nonce"],
                  let nonceData = Data(base64URLString: nonce), nonceData.count >= 16,
                  let suppliedSignature = request.headers["x-dm-signature"]
            else {
                sendError(.invalidRequest, status: 400, connection: connection)
                return
            }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            guard timestamp >= now - PeerSecurity.timestampWindowMilliseconds,
                  timestamp <= now + PeerSecurity.timestampWindowMilliseconds
            else {
                sendError(.clockMismatch, status: 401, connection: connection)
                return
            }
            let expected = PeerSecurity.signature(
                canonical: PeerSecurity.requestCanonical(timestamp: timestamp, nonce: nonce),
                secret: secret
            )
            guard PeerSecurity.constantTimeEqual(suppliedSignature, expected) else {
                sendError(.invalidSignature, status: 401, connection: connection)
                return
            }
            acceptedNonces = acceptedNonces.filter { now - $0.value <= 300_000 }
            guard acceptedNonces[nonce] == nil else {
                sendError(.replayedNonce, status: 409, connection: connection)
                return
            }
            acceptedNonces[nonce] = now

            let body = payloadBox.get()
            guard !body.isEmpty, body.count <= 65_536 else {
                sendError(.invalidResponse, status: 500, connection: connection)
                return
            }
            let responseTimestamp = Int64(Date().timeIntervalSince1970 * 1_000)
            let signature = PeerSecurity.signature(
                canonical: PeerSecurity.responseCanonical(
                    status: 200,
                    timestamp: responseTimestamp,
                    nonce: nonce,
                    body: body
                ),
                secret: secret
            )
            let headers = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/json; charset=utf-8",
                "Content-Length: \(body.count)",
                "Cache-Control: no-store",
                "Connection: close",
                "X-DM-Timestamp: \(responseTimestamp)",
                "X-DM-Nonce: \(nonce)",
                "X-DM-Signature: \(signature)",
                "X-DM-Api-Version: 1",
                "",
                ""
            ].joined(separator: "\r\n")
            send(Data(headers.utf8) + body, connection: connection)
        } catch {
            sendError(.invalidRequest, status: 400, connection: connection)
        }
    }

    private func sendError(_ error: PeerProtocolError, status: Int, connection: NWConnection) {
        let code: String
        switch error {
        case .invalidSignature: code = "invalid_signature"
        case .clockMismatch: code = "clock_mismatch"
        case .replayedNonce: code = "replayed_nonce"
        case .incompatibleVersion: code = "incompatible_version"
        default: code = "invalid_request"
        }
        let body = Data("{\"error\":\"\(code)\"}".utf8)
        let reason: String
        switch status {
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 409: reason = "Conflict"
        case 426: reason = "Upgrade Required"
        default: reason = "Internal Server Error"
        }
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        send(Data(headers.utf8) + body, connection: connection)
    }

    private func send(_ data: Data, connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class PeerServerRequest: @unchecked Sendable {
    private let id: UUID
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let completion: @Sendable (UUID, NWConnection, Data?) -> Void
    private var buffer = Data()
    private var finished = false

    init(id: UUID, connection: NWConnection, queue: DispatchQueue, completion: @escaping @Sendable (UUID, NWConnection, Data?) -> Void) {
        self.id = id
        self.connection = connection
        self.queue = queue
        self.completion = completion
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receive()
            case .failed, .cancelled:
                guard !self.finished else { return }
                self.finished = true
                self.completion(self.id, self.connection, nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.finished else { return }
            self.finished = true
            self.connection.cancel()
            self.completion(self.id, self.connection, nil)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > 16_384 || error != nil {
                self.finished = true
                self.connection.cancel()
                self.completion(self.id, self.connection, nil)
                return
            }
            if let range = self.buffer.range(of: PeerHTTPCodec.headerTerminator) {
                self.finished = true
                let request = Data(self.buffer[..<range.upperBound])
                self.completion(self.id, self.connection, request)
            } else if isComplete {
                self.finished = true
                self.connection.cancel()
                self.completion(self.id, self.connection, nil)
            } else {
                self.receive()
            }
        }
    }
}

enum PeerHTTPClient {
    static func fetch(
        endpoint: PeerEndpoint,
        deviceID: String,
        secret: Data,
        timeout: TimeInterval = 2
    ) async throws -> PeerStatusPayload {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let nonce = try PeerSecurity.generateNonce()
        let signature = PeerSecurity.signature(
            canonical: PeerSecurity.requestCanonical(timestamp: timestamp, nonce: nonce),
            secret: secret
        )
        let request = [
            "GET /v1/status HTTP/1.1",
            "Host: \(endpoint.hostHeader)",
            "Connection: close",
            "X-DM-Device-Id: \(deviceID)",
            "X-DM-Timestamp: \(timestamp)",
            "X-DM-Nonce: \(nonce)",
            "X-DM-Signature: \(signature)",
            "X-DM-Api-Version: 1",
            "",
            ""
        ].joined(separator: "\r\n")
        let responseData = try await PeerClientRequest(
            endpoint: endpoint,
            request: Data(request.utf8),
            timeout: timeout
        ).execute()
        let response = try PeerHTTPCodec.response(from: responseData)
        guard response.body.count <= 65_536 else { throw PeerProtocolError.bodyTooLarge }
        guard response.status == 200 else {
            if response.status == 426 { throw PeerProtocolError.incompatibleVersion }
            if response.status == 401 { throw PeerProtocolError.invalidSignature }
            throw PeerProtocolError.invalidResponse
        }
        guard response.headers["x-dm-api-version"] == "1",
              response.headers["x-dm-nonce"] == nonce,
              let responseTimestampText = response.headers["x-dm-timestamp"],
              let responseTimestamp = Int64(responseTimestampText),
              let responseSignature = response.headers["x-dm-signature"]
        else { throw PeerProtocolError.invalidResponse }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        guard responseTimestamp >= now - PeerSecurity.timestampWindowMilliseconds,
              responseTimestamp <= now + PeerSecurity.timestampWindowMilliseconds
        else {
            throw PeerProtocolError.clockMismatch
        }
        let expected = PeerSecurity.signature(
            canonical: PeerSecurity.responseCanonical(
                status: 200,
                timestamp: responseTimestamp,
                nonce: nonce,
                body: response.body
            ),
            secret: secret
        )
        guard PeerSecurity.constantTimeEqual(responseSignature, expected) else {
            throw PeerProtocolError.invalidSignature
        }
        let payload: PeerStatusPayload
        do {
            payload = try JSONDecoder().decode(PeerStatusPayload.self, from: response.body)
        } catch {
            throw PeerProtocolError.invalidPayload
        }
        try payload.validate()
        return payload
    }
}

private final class PeerClientRequest: @unchecked Sendable {
    private let endpoint: PeerEndpoint
    private let request: Data
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.yangyuchen.devicemonitor.peer.client", qos: .utility)
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var finished = false

    init(endpoint: PeerEndpoint, request: Data, timeout: TimeInterval) {
        self.endpoint = endpoint
        self.request = request
        self.timeout = timeout
    }

    func execute() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
                    finish(.failure(PeerProtocolError.invalidAddress))
                    return
                }
                let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.send()
                    case .failed: self.finish(.failure(PeerProtocolError.connectionFailed))
                    case .cancelled where !self.finished: self.finish(.failure(PeerProtocolError.connectionFailed))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(PeerProtocolError.timeout))
                }
            }
        }
    }

    private func send() {
        connection?.send(content: request, completion: .contentProcessed { [weak self] error in
            if error == nil { self?.receive() } else { self?.finish(.failure(PeerProtocolError.connectionFailed)) }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 81_920) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > 81_920 {
                self.finish(.failure(PeerProtocolError.bodyTooLarge))
            } else if error != nil {
                self.finish(.failure(PeerProtocolError.connectionFailed))
            } else if isComplete {
                self.finish(.success(self.buffer))
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        connection = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
