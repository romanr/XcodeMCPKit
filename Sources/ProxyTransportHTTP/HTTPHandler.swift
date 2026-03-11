import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOFoundationCompat
import NIOConcurrencyHelpers
import ProxyCore
import ProxySession
import ProxyXcodeSupport

package final class HTTPHandler: ChannelInboundHandler, Sendable {
    package typealias InboundIn = HTTPServerRequestPart
    package typealias OutboundOut = HTTPServerResponsePart

    package struct RequestLogContext: Sendable {
        package let id: String
        package let method: String
        package let path: String
        package let remoteAddress: String?
    }

    package struct State: Sendable {
        package var requestHead: HTTPRequestHead?
        package var bodyBuffer: ByteBuffer?
        package var isSSE = false
        package var sseSessionID: String?
        package var bodyTooLarge = false
    }

    package let state = NIOLockedValueBox(State())
    package let config: ProxyConfig
    package let sessionManager: any SessionManaging
    package let localResponder: LocalMCPResponder
    package let forwardingService: MCPForwardingService
    package let warmupDriver: XcodeEditorWarmupDriver
    package let windowQueryService: XcodeWindowQueryService
    package let refreshWorkflow: RefreshCodeIssuesWorkflow
    package let logger: Logger = ProxyLogging.make("http")

    package init(
        config: ProxyConfig,
        sessionManager: any SessionManaging,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        warmupDriver: XcodeEditorWarmupDriver = XcodeEditorWarmupDriver()
    ) {
        self.config = config
        self.sessionManager = sessionManager
        self.localResponder = LocalMCPResponder(
            sessionManager: sessionManager,
            logger: ProxyLogging.make("http.local")
        )
        self.forwardingService = MCPForwardingService(
            config: config,
            sessionManager: sessionManager
        )
        let refreshCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssuesCoordinator.makeDefault(
                requestTimeout: config.requestTimeout
            )
        self.warmupDriver = warmupDriver
        self.windowQueryService = XcodeWindowQueryService()
        self.refreshWorkflow = RefreshCodeIssuesWorkflow(
            coordinator: refreshCoordinator,
            warmupDriver: warmupDriver,
            logger: ProxyLogging.make("http.refresh")
        )
    }

    package func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            state.withLockedValue { state in
                state.requestHead = head
                state.bodyBuffer = context.channel.allocator.buffer(capacity: 0)
                state.bodyTooLarge = false
            }
        case .body(var buffer):
            var shouldReturn = false
            state.withLockedValue { state in
                guard var body = state.bodyBuffer, !state.bodyTooLarge else {
                    shouldReturn = true
                    return
                }
                if body.readableBytes + buffer.readableBytes > config.maxBodyBytes {
                    state.bodyTooLarge = true
                    state.bodyBuffer = body
                    shouldReturn = true
                    return
                }
                body.writeBuffer(&buffer)
                state.bodyBuffer = body
            }
            if shouldReturn {
                return
            }
        case .end:
            handleRequest(context: context)
        }
    }

    package func channelActive(context: ChannelHandlerContext) {
        if let remote = remoteAddressString(for: context.channel) {
            logger.info("Client connected", metadata: ["remote": .string(remote)])
        } else {
            logger.info("Client connected")
        }
    }

    package func channelInactive(context: ChannelHandlerContext) {
        let sessionID = state.withLockedValue { $0.sseSessionID }
        if let sessionID {
            let session = sessionManager.session(id: sessionID)
            session.notificationHub.removeSse(context.channel)
        }
        if let remote = remoteAddressString(for: context.channel) {
            if let sessionID {
                logger.info("Client disconnected", metadata: ["remote": .string(remote), "session": .string(sessionID)])
            } else {
                logger.info("Client disconnected", metadata: ["remote": .string(remote)])
            }
        } else if let sessionID {
            logger.info("Client disconnected", metadata: ["session": .string(sessionID)])
        } else {
            logger.info("Client disconnected")
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        let head = state.withLockedValue { state -> HTTPRequestHead? in
            let head = state.requestHead
            state.requestHead = nil
            return head
        }
        guard let head else { return }

        let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? head.uri
        let requestLog = RequestLogContext(
            id: UUID().uuidString,
            method: head.method.rawValue,
            path: path,
            remoteAddress: remoteAddressString(for: context.channel)
        )
        logRequest(requestLog)

        let bodyTooLarge = state.withLockedValue { $0.bodyTooLarge }
        if bodyTooLarge {
            sendPlain(
                on: context.channel,
                status: .payloadTooLarge,
                body: "request body too large",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        switch (head.method, path) {
        case (.GET, "/health"):
            sendPlain(on: context.channel, status: .ok, body: "ok", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
        case (.GET, "/debug/upstreams"):
            handleDebugSnapshot(context: context, head: head, requestLog: requestLog)
        case (.GET, "/mcp"), (.GET, "/"), (.GET, "/mcp/events"), (.GET, "/events"):
            handleSSE(context: context, head: head, requestLog: requestLog)
        case (.DELETE, "/mcp"), (.DELETE, "/"):
            handleDelete(context: context, head: head, requestLog: requestLog)
        case (.POST, "/mcp"), (.POST, "/"):
            handlePost(context: context, head: head, requestLog: requestLog)
        default:
            sendPlain(on: context.channel, status: .notFound, body: "not found", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
        }
    }

    private func handleDebugSnapshot(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard isLoopbackDebugEndpointEnabled else {
            sendPlain(
                on: context.channel,
                status: .notFound,
                body: "not found",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(sessionManager.debugSnapshot()) else {
            sendPlain(
                on: context.channel,
                status: .internalServerError,
                body: "debug snapshot unavailable",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        sendJSONData(
            on: context.channel,
            data: data,
            keepAlive: head.isKeepAlive,
            sessionID: nil,
            requestLog: requestLog
        )
    }

    private func handleSSE(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        let alreadySSE = state.withLockedValue { $0.isSSE }
        if alreadySSE {
            return
        }

        guard HTTPRequestValidator.acceptsEventStream(head.headers) else {
            sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        guard let sessionID = HTTPRequestValidator.sessionID(from: head.headers) else {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        let session = sessionManager.session(id: sessionID)
        let hadClients = session.notificationHub.hasSseClients

        state.withLockedValue { state in
            state.isSSE = true
            state.sseSessionID = sessionID
        }
        session.notificationHub.addSse(context.channel)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Mcp-Session-ID", value: sessionID)

        let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
        logResponse(requestLog, status: .ok, sessionID: sessionID)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: 8)
        buffer.writeString(": ok\n\n")
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        if !hadClients {
            let buffered = session.router.drainBufferedNotifications()
            for data in buffered {
                sendSSE(to: context.channel, data: data)
            }
        }

        if let remote = requestLog.remoteAddress {
            logger.info("SSE connected", metadata: ["remote": .string(remote), "session": .string(sessionID)])
        } else {
            logger.info("SSE connected", metadata: ["session": .string(sessionID)])
        }
    }

    private func handleDelete(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard let sessionID = HTTPRequestValidator.sessionID(from: head.headers) else {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }
        if sessionManager.hasSession(id: sessionID) {
            sessionManager.removeSession(id: sessionID)
        }
        sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionID: sessionID, requestLog: requestLog)
    }

    private func handlePost(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        let prefersEventStream: Bool
        do {
            prefersEventStream = try HTTPRequestValidator.postPreference(for: head.headers)
        } catch HTTPRequestValidationFailure.notAcceptable {
            sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept application/json or text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        } catch HTTPRequestValidationFailure.unsupportedMediaType {
            sendPlain(
                on: context.channel,
                status: .unsupportedMediaType,
                body: "content-type must be application/json",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        } catch {
            sendPlain(
                on: context.channel,
                status: .badRequest,
                body: "invalid request headers",
                keepAlive: head.isKeepAlive,
                sessionID: nil,
                requestLog: requestLog
            )
            return
        }

        let body = state.withLockedValue { state -> ByteBuffer? in
            let body = state.bodyBuffer
            state.bodyBuffer = nil
            return body
        }
        guard var body = body else {
            sendPlain(on: context.channel, status: .badRequest, body: "missing body", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
            return
        }

        guard let bodyData = body.readData(length: body.readableBytes) else {
            sendPlain(on: context.channel, status: .badRequest, body: "invalid body", keepAlive: head.isKeepAlive, sessionID: nil, requestLog: requestLog)
            return
        }

        let headerSessionID = HTTPRequestValidator.sessionID(from: head.headers)
        let headerSessionExists = headerSessionID.map { sessionManager.hasSession(id: $0) } ?? false

        if let object = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any],
            let localHandling = localResponder.handle(
                object: object,
                headerSessionID: headerSessionID,
                headerSessionExists: headerSessionExists,
                eventLoop: context.eventLoop
            )
        {
            handleLocalPostHandling(
                localHandling,
                on: context.channel,
                prefersEventStream: prefersEventStream,
                keepAlive: head.isKeepAlive,
                requestLog: requestLog
            )
            return
        }

        if let headerSessionID, !headerSessionExists {
            _ = sessionManager.session(id: headerSessionID)
        }

        let sessionID = headerSessionID ?? UUID().uuidString
        let requestMetadata = MCPErrorResponder.requestMetadata(from: bodyData)
        let requestIDs = requestMetadata.ids
        let requestIsBatch = requestMetadata.isBatch
        let parsedRequestJSON = try? JSONSerialization.jsonObject(with: bodyData, options: [])

        if sessionManager.isInitialized() == false {
            if requestIDs.isEmpty {
                sendPlain(
                    on: context.channel,
                    status: .unprocessableEntity,
                    body: "expected initialize request",
                    keepAlive: head.isKeepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            } else {
                sendMCPError(
                    on: context.channel,
                    ids: requestIDs,
                    code: -32000,
                    message: "expected initialize request",
                    forceBatchArray: requestIsBatch,
                    prefersEventStream: prefersEventStream,
                    keepAlive: head.isKeepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            }
            return
        }

        guard let parsedRequestJSON else {
            sendMCPError(
                on: context.channel,
                id: nil,
                code: -32700,
                message: "invalid json",
                prefersEventStream: prefersEventStream,
                keepAlive: head.isKeepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }

        let refreshRequest = requestIsBatch ? nil : refreshCodeIssuesRequest(from: parsedRequestJSON)
        if let refreshRequest, requestIDs.isEmpty == false {
            if headerSessionID == nil {
                sendMCPError(
                    on: context.channel,
                    ids: requestIDs,
                    code: -32000,
                    message: "expected initialize request",
                    forceBatchArray: requestIsBatch,
                    prefersEventStream: prefersEventStream,
                    keepAlive: head.isKeepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
                return
            }

            let keepAlive = head.isKeepAlive
            let channel = context.channel
            let eventLoop = context.eventLoop
            let promise = eventLoop.makePromise(of: RefreshForwardAttemptResult.self)
            promise.futureResult.whenSuccess { attemptResult in
                self.respondToRefreshForwardAttempt(
                    attemptResult,
                    on: channel,
                    prefersEventStream: prefersEventStream,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            }
            Task { [self] in
                let attemptResult = await forwardRefreshCodeIssuesRequest(
                    refreshRequest,
                    bodyData: bodyData,
                    sessionID: sessionID,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    eventLoop: eventLoop
                )
                promise.succeed(attemptResult)
            }
            return
        }

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                sessionID: sessionID
            ) else {
                if requestIDs.isEmpty {
                    sendPlain(
                        on: context.channel,
                        status: .serviceUnavailable,
                        body: "upstream unavailable",
                        keepAlive: head.isKeepAlive,
                        sessionID: sessionID,
                        requestLog: requestLog
                    )
                } else {
                    sendMCPError(
                        on: context.channel,
                        ids: requestIDs,
                        code: -32001,
                        message: "upstream unavailable",
                        forceBatchArray: requestIsBatch,
                        prefersEventStream: prefersEventStream,
                        keepAlive: head.isKeepAlive,
                        sessionID: sessionID,
                        requestLog: requestLog
                    )
                }
                return
            }
            prepared = candidate
        } catch {
            sendMCPError(
                on: context.channel,
                id: nil,
                code: -32700,
                message: "invalid json",
                prefersEventStream: prefersEventStream,
                keepAlive: head.isKeepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }

        if prepared.transform.method == "tools/list" {
            let hasCache = sessionManager.cachedToolsListResult() != nil
            let params = (try? JSONSerialization.jsonObject(with: bodyData, options: []))
                .flatMap { $0 as? [String: Any] }?["params"]
            let hasParams = params != nil && !(params is NSNull)
            logger.debug(
                "tools/list cache miss; forwarding upstream",
                metadata: [
                    "session": .string(sessionID),
                    "has_cache": .string(hasCache ? "true" : "false"),
                    "has_params": .string(hasParams ? "true" : "false"),
                    "upstream": .string("\(prepared.upstreamIndex)"),
                ]
            )
        }

        if headerSessionID == nil {
            if prepared.transform.isBatch || prepared.transform.method != "initialize" || !prepared.transform.expectsResponse {
                if prepared.transform.responseIDs.isEmpty {
                    sendPlain(
                        on: context.channel,
                        status: .unprocessableEntity,
                        body: "expected initialize request",
                        keepAlive: head.isKeepAlive,
                        sessionID: sessionID,
                        requestLog: requestLog
                    )
                } else {
                    sendMCPError(
                        on: context.channel,
                        ids: prepared.transform.responseIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: prepared.transform.isBatch,
                        prefersEventStream: prefersEventStream,
                        keepAlive: head.isKeepAlive,
                        sessionID: sessionID,
                        requestLog: requestLog
                    )
                }
                return
            }
        }

        let session = sessionManager.session(id: sessionID)

        if prepared.transform.expectsResponse {
            let started: MCPForwardingService.StartedRequest
            do {
                started = try forwardingService.startRequest(
                    prepared,
                    session: session,
                    on: context.eventLoop
                )
            } catch {
                sendMCPError(
                    on: context.channel,
                    id: nil,
                    code: -32600,
                    message: "missing id",
                    prefersEventStream: prefersEventStream,
                    keepAlive: head.isKeepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
                return
            }

            let keepAlive = head.isKeepAlive
            let sessionIDCopy = sessionID
            let channel = context.channel
            started.future.whenComplete { result in
                switch self.forwardingService.resolveResponse(
                    result,
                    started: started,
                    sessionID: sessionIDCopy
                ) {
                case .success(let responseData):
                    if prefersEventStream {
                        self.sendSingleSSE(on: channel, data: responseData, keepAlive: keepAlive, sessionID: sessionIDCopy, requestLog: requestLog)
                    } else {
                        var out = channel.allocator.buffer(capacity: responseData.count)
                        out.writeBytes(responseData)
                        self.sendJSON(on: channel, buffer: out, keepAlive: keepAlive, sessionID: sessionIDCopy, requestLog: requestLog)
                    }
                case .invalidUpstreamResponse:
                    self.sendPlain(on: channel, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionID: sessionIDCopy, requestLog: requestLog)
                case .timeout:
                    self.sendMCPError(
                        on: channel,
                        ids: started.transform.responseIDs,
                        code: -32000,
                        message: "upstream timeout",
                        forceBatchArray: started.transform.isBatch,
                        prefersEventStream: prefersEventStream,
                        keepAlive: keepAlive,
                        sessionID: sessionIDCopy,
                        requestLog: requestLog
                    )
                }
            }
        } else {
            if prepared.transform.method == "notifications/initialized" && sessionManager.isInitialized() {
                sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionID: sessionID, requestLog: requestLog)
            } else {
                sessionManager.sendUpstream(prepared.transform.upstreamData, upstreamIndex: prepared.upstreamIndex)
                sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionID: sessionID, requestLog: requestLog)
            }
        }
    }

}
