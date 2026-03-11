import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOFoundationCompat
import NIOConcurrencyHelpers
import XcodeMCPProxyCore
import XcodeMCPProxySession
import XcodeMCPProxyXcodeSupport
import XcodeMCPProxyCore
import XcodeMCPProxySession
import XcodeMCPProxyXcodeSupport

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
        package var sseSessionId: String?
        package var bodyTooLarge = false
    }

    package struct RefreshCodeIssuesRequest: Sendable {
        package static let toolName = "XcodeRefreshCodeIssuesInFile"
        package static let globalQueueKey = "__global__"

        package let tabIdentifier: String?
        package let filePath: String?

        package var queueKey: String {
            guard let tabIdentifier, tabIdentifier.isEmpty == false else {
                return Self.globalQueueKey
            }
            return tabIdentifier
        }
    }

    package struct PreparedForwardRequest {
        package let transform: RequestTransform
        package let upstreamIndex: Int
    }

    package struct StartedForwardRequest {
        package let transform: RequestTransform
        package let upstreamIndex: Int
        package let future: EventLoopFuture<ByteBuffer>
    }

    package enum ForwardResponseResolution {
        case success(Data)
        case timeout
        case invalidUpstreamResponse
    }

    package enum RefreshForwardAttemptResult {
        case success(Data)
        case timeout(responseIds: [RPCId], isBatch: Bool)
        case upstreamUnavailable(responseIds: [RPCId], isBatch: Bool)
        case overloaded(responseIds: [RPCId], isBatch: Bool)
        case invalidRequest
        case invalidUpstreamResponse
    }

    static let refreshRetryDelaysNanos: [UInt64] = [
        200_000_000,
        500_000_000,
    ]

    package let state = NIOLockedValueBox(State())
    package let config: ProxyConfig
    package let sessionManager: any SessionManaging
    package let refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator
    package let warmupDriver: XcodeEditorWarmupDriver
    package let logger: Logger = ProxyLogging.make("http")

    package init(
        config: ProxyConfig,
        sessionManager: any SessionManaging,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        warmupDriver: XcodeEditorWarmupDriver = XcodeEditorWarmupDriver()
    ) {
        self.config = config
        self.sessionManager = sessionManager
        self.refreshCodeIssuesCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssuesCoordinator.makeDefault(
                requestTimeout: config.requestTimeout
            )
        self.warmupDriver = warmupDriver
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
        let sessionId = state.withLockedValue { $0.sseSessionId }
        if let sessionId {
            let session = sessionManager.session(id: sessionId)
            session.notificationHub.removeSse(context.channel)
        }
        if let remote = remoteAddressString(for: context.channel) {
            if let sessionId {
                logger.info("Client disconnected", metadata: ["remote": .string(remote), "session": .string(sessionId)])
            } else {
                logger.info("Client disconnected", metadata: ["remote": .string(remote)])
            }
        } else if let sessionId {
            logger.info("Client disconnected", metadata: ["session": .string(sessionId)])
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
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }

        switch (head.method, path) {
        case (.GET, "/health"):
            sendPlain(on: context.channel, status: .ok, body: "ok", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
        case (.GET, "/debug/upstreams"):
            handleDebugSnapshot(context: context, head: head, requestLog: requestLog)
        case (.GET, "/mcp"), (.GET, "/"), (.GET, "/mcp/events"), (.GET, "/events"):
            handleSSE(context: context, head: head, requestLog: requestLog)
        case (.DELETE, "/mcp"), (.DELETE, "/"):
            handleDelete(context: context, head: head, requestLog: requestLog)
        case (.POST, "/mcp"), (.POST, "/"):
            handlePost(context: context, head: head, requestLog: requestLog)
        default:
            sendPlain(on: context.channel, status: .notFound, body: "not found", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
        }
    }

    private func handleDebugSnapshot(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard isLoopbackDebugEndpointEnabled else {
            sendPlain(
                on: context.channel,
                status: .notFound,
                body: "not found",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
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
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }

        sendJSONData(
            on: context.channel,
            data: data,
            keepAlive: head.isKeepAlive,
            sessionId: nil,
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
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }

        guard let sessionId = HTTPRequestValidator.sessionId(from: head.headers) else {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }

        let session = sessionManager.session(id: sessionId)
        let hadClients = session.notificationHub.hasSseClients

        state.withLockedValue { state in
            state.isSSE = true
            state.sseSessionId = sessionId
        }
        session.notificationHub.addSse(context.channel)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Mcp-Session-Id", value: sessionId)

        let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
        logResponse(requestLog, status: .ok, sessionId: sessionId)
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
            logger.info("SSE connected", metadata: ["remote": .string(remote), "session": .string(sessionId)])
        } else {
            logger.info("SSE connected", metadata: ["session": .string(sessionId)])
        }
    }

    private func handleDelete(context: ChannelHandlerContext, head: HTTPRequestHead, requestLog: RequestLogContext) {
        guard let sessionId = HTTPRequestValidator.sessionId(from: head.headers) else {
            sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
                requestLog: requestLog
            )
            return
        }
        if sessionManager.hasSession(id: sessionId) {
            sessionManager.removeSession(id: sessionId)
        }
        sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
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
                sessionId: nil,
                requestLog: requestLog
            )
            return
        } catch HTTPRequestValidationFailure.unsupportedMediaType {
            sendPlain(
                on: context.channel,
                status: .unsupportedMediaType,
                body: "content-type must be application/json",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
                requestLog: requestLog
            )
            return
        } catch {
            sendPlain(
                on: context.channel,
                status: .badRequest,
                body: "invalid request headers",
                keepAlive: head.isKeepAlive,
                sessionId: nil,
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
            sendPlain(on: context.channel, status: .badRequest, body: "missing body", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
            return
        }

        guard let bodyData = body.readData(length: body.readableBytes) else {
            sendPlain(on: context.channel, status: .badRequest, body: "invalid body", keepAlive: head.isKeepAlive, sessionId: nil, requestLog: requestLog)
            return
        }

        let headerSessionId = HTTPRequestValidator.sessionId(from: head.headers)
        let headerSessionExists = headerSessionId.map { sessionManager.hasSession(id: $0) } ?? false

        if let object = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any],
           let method = object["method"] as? String {
            if method == "initialize" {
                guard let originalIdValue = object["id"], let originalId = RPCId(any: originalIdValue) else {
                    sendMCPError(
                        on: context.channel,
                        id: nil,
                        code: -32600,
                        message: "missing id",
                        prefersEventStream: prefersEventStream,
                        keepAlive: head.isKeepAlive,
                        sessionId: headerSessionId ?? UUID().uuidString,
                        requestLog: requestLog
                    )
                    return
                }
                let sessionId = headerSessionId ?? UUID().uuidString
                _ = sessionManager.session(id: sessionId)
                let future = sessionManager.registerInitialize(
                    sessionId: sessionId,
                    originalId: originalId,
                    requestObject: object,
                    on: context.eventLoop
                )
                let keepAlive = head.isKeepAlive
                let channel = context.channel
                future.whenComplete { result in
                    switch result {
                    case .success(let buffer):
                        var buffer = buffer
                        guard let data = buffer.readData(length: buffer.readableBytes) else {
                            self.sendPlain(on: channel, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
                            return
                        }
                        if prefersEventStream {
                            self.sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
                        } else {
                            var out = channel.allocator.buffer(capacity: data.count)
                            out.writeBytes(data)
                            self.sendJSON(on: channel, buffer: out, keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
                        }
                    case .failure:
                        self.sendMCPError(
                            on: channel,
                            id: originalId,
                            code: -32000,
                            message: "upstream timeout",
                            prefersEventStream: prefersEventStream,
                            keepAlive: keepAlive,
                            sessionId: sessionId,
                            requestLog: requestLog
                        )
                    }
                }
                return
            }

            // Xcode MCP (via `xcrun mcpbridge`) currently doesn't implement the MCP Resources APIs.
            // Some clients still probe `resources/list` and `resources/templates/list` unconditionally.
            //
            // If the proxy hasn't been initialized yet, we can't reliably forward these requests. Serve an
            // empty list response locally so clients don't choke on unsupported-method errors.
            if (method == "resources/list" || method == "resources/templates/list") && sessionManager.isInitialized() == false {
                guard let originalIdValue = object["id"], let originalId = RPCId(any: originalIdValue) else {
                    sendMCPError(
                        on: context.channel,
                        id: nil,
                        code: -32600,
                        message: "missing id",
                        prefersEventStream: prefersEventStream,
                        keepAlive: head.isKeepAlive,
                        sessionId: headerSessionId ?? UUID().uuidString,
                        requestLog: requestLog
                    )
                    return
                }

                let sessionId = headerSessionId ?? UUID().uuidString
                if let headerSessionId, headerSessionExists == false {
                    _ = sessionManager.session(id: headerSessionId)
                }

                let result: [String: Any]
                if method == "resources/list" {
                    result = [
                        "resources": [Any](),
                    ]
                } else {
                    result = [
                        "resourceTemplates": [Any](),
                    ]
                }

                let response: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": originalId.value.foundationObject,
                    "result": result,
                ]
                if JSONSerialization.isValidJSONObject(response),
                   let data = try? JSONSerialization.data(withJSONObject: response, options: []) {
                    if prefersEventStream {
                        sendSingleSSE(on: context.channel, data: data, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
                    } else {
                        var out = context.channel.allocator.buffer(capacity: data.count)
                        out.writeBytes(data)
                        sendJSON(on: context.channel, buffer: out, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
                    }
                    return
                }
            }

            // Serve cached tools/list regardless of params. Some clients attach pagination-like params,
            // but Codex startup expects a full tool list quickly; stability wins over strict pagination.
            if method == "tools/list",
               let headerSessionId,
               sessionManager.isInitialized(),
               let cachedResult = sessionManager.cachedToolsListResult(),
               let originalIdValue = object["id"],
               let originalId = RPCId(any: originalIdValue) {
                if headerSessionExists == false {
                    _ = sessionManager.session(id: headerSessionId)
                }
                let hasParams: Bool = {
                    guard let params = object["params"] else { return false }
                    return !(params is NSNull)
                }()
                // Even when tools/list is served from cache, pin the session so later upstream messages
                // route consistently instead of fanning out across unpinned sessions.
                let pinnedUpstreamIndex = sessionManager.chooseUpstreamIndex(sessionId: headerSessionId, shouldPin: true)
                logger.debug(
                    "tools/list cache hit",
                    metadata: [
                        "session": .string(headerSessionId),
                        "has_params": .string(hasParams ? "true" : "false"),
                        "pinned_upstream": .string(pinnedUpstreamIndex.map(String.init) ?? "none"),
                    ]
                )
                // Intentionally do not refresh tools/list in the background.
                // Once we have a valid tool list, keeping it stable for the lifetime of the proxy
                // avoids upstream churn (and Xcode permission prompts) caused by best-effort refreshes.
                let response: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": originalId.value.foundationObject,
                    "result": cachedResult.foundationObject,
                ]
                if JSONSerialization.isValidJSONObject(response),
                   let data = try? JSONSerialization.data(withJSONObject: response, options: []) {
                    if prefersEventStream {
                        sendSingleSSE(on: context.channel, data: data, keepAlive: head.isKeepAlive, sessionId: headerSessionId, requestLog: requestLog)
                    } else {
                        var out = context.channel.allocator.buffer(capacity: data.count)
                        out.writeBytes(data)
                        sendJSON(on: context.channel, buffer: out, keepAlive: head.isKeepAlive, sessionId: headerSessionId, requestLog: requestLog)
                    }
                    return
                }
            }
        }

        if let headerSessionId, !headerSessionExists {
            _ = sessionManager.session(id: headerSessionId)
        }

        let sessionId = headerSessionId ?? UUID().uuidString
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
                    sessionId: sessionId,
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
                    sessionId: sessionId,
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
                sessionId: sessionId,
                requestLog: requestLog
            )
            return
        }

        let refreshRequest = requestIsBatch ? nil : refreshCodeIssuesRequest(from: parsedRequestJSON)
        if let refreshRequest, requestIDs.isEmpty == false {
            if headerSessionId == nil {
                sendMCPError(
                    on: context.channel,
                    ids: requestIDs,
                    code: -32000,
                    message: "expected initialize request",
                    forceBatchArray: requestIsBatch,
                    prefersEventStream: prefersEventStream,
                    keepAlive: head.isKeepAlive,
                    sessionId: sessionId,
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
                    sessionId: sessionId,
                    requestLog: requestLog
                )
            }
            Task { [self] in
                let attemptResult = await forwardRefreshCodeIssuesRequest(
                    refreshRequest,
                    bodyData: bodyData,
                    sessionId: sessionId,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    eventLoop: eventLoop
                )
                promise.succeed(attemptResult)
            }
            return
        }

        let prepared: PreparedForwardRequest
        do {
            guard let candidate = try prepareForwardRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                sessionId: sessionId
            ) else {
                if requestIDs.isEmpty {
                    sendPlain(
                        on: context.channel,
                        status: .serviceUnavailable,
                        body: "upstream unavailable",
                        keepAlive: head.isKeepAlive,
                        sessionId: sessionId,
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
                        sessionId: sessionId,
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
                sessionId: sessionId,
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
                    "session": .string(sessionId),
                    "has_cache": .string(hasCache ? "true" : "false"),
                    "has_params": .string(hasParams ? "true" : "false"),
                    "upstream": .string("\(prepared.upstreamIndex)"),
                ]
            )
        }

        if headerSessionId == nil {
            if prepared.transform.isBatch || prepared.transform.method != "initialize" || !prepared.transform.expectsResponse {
                if prepared.transform.responseIds.isEmpty {
                    sendPlain(
                        on: context.channel,
                        status: .unprocessableEntity,
                        body: "expected initialize request",
                        keepAlive: head.isKeepAlive,
                        sessionId: sessionId,
                        requestLog: requestLog
                    )
                } else {
                    sendMCPError(
                        on: context.channel,
                        ids: prepared.transform.responseIds,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: prepared.transform.isBatch,
                        prefersEventStream: prefersEventStream,
                        keepAlive: head.isKeepAlive,
                        sessionId: sessionId,
                        requestLog: requestLog
                    )
                }
                return
            }
        }

        let session = sessionManager.session(id: sessionId)

        if prepared.transform.expectsResponse {
            let started: StartedForwardRequest
            do {
                started = try startPreparedForwardRequest(
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
                    sessionId: sessionId,
                    requestLog: requestLog
                )
                return
            }

            let keepAlive = head.isKeepAlive
            let sessionIdCopy = sessionId
            let channel = context.channel
            started.future.whenComplete { result in
                switch self.resolveForwardResponse(
                    result,
                    started: started,
                    sessionId: sessionIdCopy
                ) {
                case .success(let responseData):
                    if prefersEventStream {
                        self.sendSingleSSE(on: channel, data: responseData, keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                    } else {
                        var out = channel.allocator.buffer(capacity: responseData.count)
                        out.writeBytes(responseData)
                        self.sendJSON(on: channel, buffer: out, keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                    }
                case .invalidUpstreamResponse:
                    self.sendPlain(on: channel, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                case .timeout:
                    self.sendMCPError(
                        on: channel,
                        ids: started.transform.responseIds,
                        code: -32000,
                        message: "upstream timeout",
                        forceBatchArray: started.transform.isBatch,
                        prefersEventStream: prefersEventStream,
                        keepAlive: keepAlive,
                        sessionId: sessionIdCopy,
                        requestLog: requestLog
                    )
                }
            }
        } else {
            if prepared.transform.method == "notifications/initialized" && sessionManager.isInitialized() {
                sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
            } else {
                sessionManager.sendUpstream(prepared.transform.upstreamData, upstreamIndex: prepared.upstreamIndex)
                sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
            }
        }
    }

}
