import Foundation
import Logging

public actor StdioAdapter {
    private struct RequestEnvelope {
        let ids: [JSONValue]

        var expectsResponse: Bool {
            !ids.isEmpty
        }
    }

    private enum AdapterError: Error {
        case invalidResponse
        case httpStatus(Int)
    }

    private let upstreamURL: URL
    private let requestTimeout: TimeInterval
    private let inputHandle: FileHandle
    private let outputWriter: StdioWriter
    private let logger: Logger
    private let session: URLSession
    private let sessionId: String
    private var framer = StdioFramer()
    private var readTask: Task<Void, Never>?
    private var sseTask: Task<Void, Never>?
    private var started = false
    private var stopped = false

    public init(
        upstreamURL: URL,
        requestTimeout: TimeInterval,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.upstreamURL = upstreamURL
        self.requestTimeout = requestTimeout
        self.inputHandle = input
        self.logger = ProxyLogging.make("stdio.adapter")
        self.outputWriter = StdioWriter(handle: output, logger: logger)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
        self.sessionId = "stdio-\(UUID().uuidString)"
    }

    public func start() async {
        guard !started else { return }
        started = true
        sseTask = Task { [weak self] in
            await self?.sseLoop()
        }
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func wait() async {
        _ = await readTask?.value
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        readTask?.cancel()
        sseTask?.cancel()
        readTask = nil
        sseTask = nil
        session.invalidateAndCancel()
    }

    private func readLoop() async {
        defer {
            Task { [weak self] in
                await self?.stop()
            }
        }

        do {
            for try await byte in inputHandle.bytes {
                if Task.isCancelled { break }
                handleInput(Data([byte]))
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("STDIO read failed", metadata: ["error": "\(error)"])
        }
    }

    private func handleInput(_ data: Data) {
        let result = framer.append(data)
        for recovery in result.recoveries {
            logger.warning(
                "Recovered STDIO input stream corruption",
                metadata: [
                    "kind": "\(recovery.kind.rawValue)",
                    "dropped_prefix_bytes": "\(recovery.droppedPrefixBytes)",
                    "candidate_offset": "\(recovery.candidateOffset.map(String.init) ?? "none")",
                ]
            )
        }
        for message in result.messages {
            Task { [weak self] in
                await self?.processMessage(message)
            }
        }
    }

    private func processMessage(_ data: Data) async {
        if stopped { return }
        let envelope = inspectRequest(data)
        do {
            let responseData = try await sendRequest(data)
            if let responseData {
                await outputWriter.send(responseData)
            } else if envelope.expectsResponse {
                await emitError(for: envelope, message: "upstream returned empty response")
            }
        } catch let error as AdapterError {
            logger.error("STDIO upstream request failed", metadata: ["error": "\(error)"])
            switch error {
            case .httpStatus(let status):
                await emitError(for: envelope, message: "upstream HTTP \(status)")
            case .invalidResponse:
                await emitError(for: envelope, message: "invalid upstream response")
            }
        } catch {
            logger.error("STDIO upstream request failed", metadata: ["error": "\(error)"])
            await emitError(for: envelope, message: "upstream unavailable")
        }
    }

    private func sendRequest(_ data: Data) async throws -> Data? {
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        applyTimeout(to: &request)
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AdapterError.invalidResponse
        }
        if (200...299).contains(http.statusCode) {
            guard !responseData.isEmpty else { return nil }
            guard isValidJSONPayload(responseData) else {
                throw AdapterError.invalidResponse
            }
            return responseData
        }
        if !responseData.isEmpty, isValidJSONPayload(responseData) {
            return responseData
        }
        throw AdapterError.httpStatus(http.statusCode)
    }

    private func sseLoop() async {
        var attempt = 0
        while !stopped {
            do {
                try await consumeSSE()
                attempt = 0
            } catch is CancellationError {
                return
            } catch {
                logger.warning("SSE disconnected", metadata: ["error": "\(error)"])
            }

            if stopped { break }
            let delay = backoffDelay(for: attempt)
            attempt += 1
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func consumeSSE() async throws {
        var request = URLRequest(url: upstreamURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        applyTimeout(to: &request, allowLongRunning: true)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AdapterError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw AdapterError.httpStatus(http.statusCode)
        }

        var decoder = SSEDecoder()
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard let payload = decoder.feed(line: line) else { continue }
            guard isValidJSONPayload(payload) else {
                logger.warning("Dropping invalid SSE payload", metadata: ["bytes": "\(payload.count)"])
                continue
            }
            await outputWriter.send(payload)
        }

        // If the stream ends without a terminating blank line, flush any buffered event.
        if let tail = decoder.flushIfNeeded(), isValidJSONPayload(tail) {
            await outputWriter.send(tail)
        }
    }

    private func applyTimeout(to request: inout URLRequest, allowLongRunning: Bool = false) {
        if allowLongRunning {
            request.timeoutInterval = .infinity
            return
        }
        if requestTimeout > 0 {
            request.timeoutInterval = requestTimeout
        } else {
            request.timeoutInterval = .infinity
        }
    }

    private func isValidJSONPayload(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return json is [String: Any] || json is [Any]
    }

    private func backoffDelay(for attempt: Int) -> UInt64 {
        let capped = min(attempt, 4)
        let seconds = min(5.0, 0.5 * Double(1 << capped))
        return UInt64(seconds * 1_000_000_000)
    }

    private func inspectRequest(_ data: Data) -> RequestEnvelope {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return RequestEnvelope(ids: [])
        }
        if let object = json as? [String: Any] {
            if let id = object["id"], !(id is NSNull), let jsonId = JSONValue(any: id) {
                return RequestEnvelope(ids: [jsonId])
            }
            return RequestEnvelope(ids: [])
        }
        if let array = json as? [Any] {
            var ids: [JSONValue] = []
            for item in array {
                guard let object = item as? [String: Any] else { continue }
                if let id = object["id"], !(id is NSNull), let jsonId = JSONValue(any: id) {
                    ids.append(jsonId)
                }
            }
            return RequestEnvelope(ids: ids)
        }
        return RequestEnvelope(ids: [])
    }

    private func emitError(for envelope: RequestEnvelope, message: String) async {
        guard envelope.expectsResponse else { return }
        guard let payload = errorPayload(ids: envelope.ids, message: message) else { return }
        await outputWriter.send(payload)
    }

    private func errorPayload(ids: [JSONValue], message: String) -> Data? {
        let error: [String: Any] = [
            "code": -32000,
            "message": message,
        ]

        if ids.count == 1, let id = ids.first {
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id.foundationObject,
                "error": error,
            ]
            return try? JSONSerialization.data(withJSONObject: response, options: [])
        }

        let responses: [[String: Any]] = ids.map { id in
            [
                "jsonrpc": "2.0",
                "id": id.foundationObject,
                "error": error,
            ]
        }
        guard !responses.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: responses, options: [])
    }
}
