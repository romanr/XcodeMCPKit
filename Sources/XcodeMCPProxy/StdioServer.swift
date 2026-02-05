import Foundation
import Logging
import NIO

actor StdioServer {
    private let sessionManager: any SessionManaging
    private let eventLoop: EventLoop
    private let inputHandle: FileHandle
    private let outputWriter: StdioWriter
    private let logger: Logger
    private var framer = StdioFramer()
    private var readTask: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var sessionId: String?
    private var stdioAttached = false

    init(
        sessionManager: any SessionManaging,
        eventLoop: EventLoop,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.sessionManager = sessionManager
        self.eventLoop = eventLoop
        self.inputHandle = input
        self.logger = ProxyLogging.make("stdio")
        self.outputWriter = StdioWriter(handle: output, logger: logger)
    }

    func start() async {
        guard !started else { return }
        started = true
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func wait() async {
        _ = await readTask?.value
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        readTask?.cancel()
        readTask = nil
        detachWriter()
    }

    private func readLoop() async {
        defer { finish() }
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

    private func finish() {
        guard !stopped else { return }
        stopped = true
        readTask = nil
        detachWriter()
    }

    private func detachWriter() {
        if let sessionId, sessionManager.hasSession(id: sessionId) {
            let session = sessionManager.session(id: sessionId)
            session.notificationHub.detachStdioWriter()
        }
    }

    private func handleInput(_ data: Data) {
        let messages = framer.append(data)
        for message in messages {
            processMessage(message)
        }
    }

    private func processMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            logger.error("Failed to parse stdin JSON")
            return
        }

        let sessionId = ensureSessionId()
        let session = sessionManager.session(id: sessionId)

        if let object = json as? [String: Any],
           let method = object["method"] as? String,
           method == "initialize" {
            guard let originalIdValue = object["id"],
                  let originalId = RPCId(any: originalIdValue) else {
                logger.error("STDIO initialize missing id")
                return
            }
            let future = sessionManager.registerInitialize(
                originalId: originalId,
                requestObject: object,
                on: eventLoop
            )
            future.whenComplete { [weak self] result in
                Task { await self?.handleResponse(result) }
            }
            return
        }

        let transform: RequestTransform
        do {
            transform = try RequestInspector.transform(
                data,
                sessionId: sessionId,
                mapId: { sessionId, originalId in
                    sessionManager.assignUpstreamId(sessionId: sessionId, originalId: originalId)
                }
            )
        } catch {
            logger.error("STDIO invalid JSON payload")
            return
        }

        if transform.expectsResponse {
            let future: EventLoopFuture<ByteBuffer>
            if transform.isBatch {
                future = session.router.registerBatch(on: eventLoop)
            } else if let idKey = transform.idKey {
                future = session.router.registerRequest(idKey: idKey, on: eventLoop)
            } else {
                logger.error("STDIO request missing id")
                return
            }

            sessionManager.sendUpstream(transform.upstreamData)
            future.whenComplete { [weak self] result in
                Task { await self?.handleResponse(result) }
            }
        } else {
            if transform.method == "notifications/initialized", sessionManager.isInitialized() {
                return
            }
            sessionManager.sendUpstream(transform.upstreamData)
        }
    }

    private func handleResponse(_ result: Result<ByteBuffer, Error>) async {
        switch result {
        case .success(var buffer):
            guard let data = buffer.readData(length: buffer.readableBytes) else {
                logger.error("STDIO invalid upstream response")
                return
            }
            await outputWriter.send(data)
        case .failure:
            logger.error("STDIO upstream timeout")
        }
    }

    private func ensureSessionId() -> String {
        if let sessionId {
            return sessionId
        }
        let newId = "stdio-\(UUID().uuidString)"
        sessionId = newId

        if !stdioAttached {
            stdioAttached = true
            let session = sessionManager.session(id: newId)
            session.notificationHub.attachStdioWriter(outputWriter)
            let buffered = session.router.drainBufferedNotifications()
            for data in buffered {
                session.notificationHub.broadcast(data)
            }
        }

        return newId
    }
}
