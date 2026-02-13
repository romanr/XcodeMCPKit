import Foundation
import Logging
import NIO
import NIOHTTP1
import NIOFoundationCompat
import NIOConcurrencyHelpers

final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct RequestLogContext: Sendable {
        let id: String
        let method: String
        let path: String
        let remoteAddress: String?
    }

    private struct State: Sendable {
        var requestHead: HTTPRequestHead?
        var bodyBuffer: ByteBuffer?
        var isSSE = false
        var sseSessionId: String?
        var bodyTooLarge = false
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig
    private let sessionManager: any SessionManaging
    private let logger: Logger = ProxyLogging.make("http")

    init(config: ProxyConfig, sessionManager: any SessionManaging) {
        self.config = config
        self.sessionManager = sessionManager
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
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

    func channelActive(context: ChannelHandlerContext) {
        if let remote = remoteAddressString(for: context.channel) {
            logger.info("Client connected", metadata: ["remote": .string(remote)])
        } else {
            logger.info("Client connected")
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
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

        let shouldPinUpstream = MCPMethodDispatcher.shouldPinUpstream(for: parsedRequestJSON)
        guard let upstreamIndex = sessionManager.chooseUpstreamIndex(sessionId: sessionId, shouldPin: shouldPinUpstream) else {
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

        let transform: RequestTransform
        do {
            transform = try RequestInspector.transform(
                bodyData,
                sessionId: sessionId,
                mapId: { sessionId, originalId in
                    sessionManager.assignUpstreamId(
                        sessionId: sessionId,
                        originalId: originalId,
                        upstreamIndex: upstreamIndex
                    )
                }
            )
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

        if transform.method == "tools/list" {
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
                    "upstream": .string("\(upstreamIndex)"),
                ]
            )
        }

        if headerSessionId == nil {
            if transform.isBatch || transform.method != "initialize" || !transform.expectsResponse {
                if transform.responseIds.isEmpty {
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
                        ids: transform.responseIds,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: transform.isBatch,
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

        if transform.expectsResponse {
            let future: EventLoopFuture<ByteBuffer>
            let requestTimeout = MCPMethodDispatcher.timeoutForMethod(
                transform.method,
                defaultSeconds: config.requestTimeout
            )
            if transform.isBatch {
                future = session.router.registerBatch(on: context.eventLoop, timeout: requestTimeout)
            } else if let idKey = transform.idKey {
                future = session.router.registerRequest(idKey: idKey, on: context.eventLoop, timeout: requestTimeout)
            } else {
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

            sessionManager.sendUpstream(transform.upstreamData, upstreamIndex: upstreamIndex)
            let keepAlive = head.isKeepAlive
            let sessionIdCopy = sessionId
            let channel = context.channel
            future.whenComplete { result in
                switch result {
                case .success(let buffer):
                    var buffer = buffer
                    guard let data = buffer.readData(length: buffer.readableBytes) else {
                        self.sendPlain(on: channel, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                        return
                    }
                    let responseData = self.rewriteUnsupportedResourcesListResponseIfNeeded(
                        method: transform.method,
                        originalId: transform.originalId,
                        upstreamData: data
                    )
                    if transform.isCacheableToolsListRequest,
                       let object = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
                       let resultAny = object["result"],
                       let result = JSONValue(any: resultAny) {
                        self.sessionManager.setCachedToolsListResult(result)
                    }
                    if self.shouldNotifyUpstreamSuccess(for: responseData) {
                        for responseId in transform.responseIds {
                            self.sessionManager.onRequestSucceeded(
                                sessionId: sessionIdCopy,
                                requestIdKey: responseId.key,
                                upstreamIndex: upstreamIndex
                            )
                        }
                    }
                    if prefersEventStream {
                        self.sendSingleSSE(on: channel, data: responseData, keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                    } else {
                        var out = channel.allocator.buffer(capacity: responseData.count)
                        out.writeBytes(responseData)
                        self.sendJSON(on: channel, buffer: out, keepAlive: keepAlive, sessionId: sessionIdCopy, requestLog: requestLog)
                    }
                case .failure:
                    if let firstResponseId = transform.responseIds.first {
                        self.sessionManager.onRequestTimeout(
                            sessionId: sessionIdCopy,
                            requestIdKey: firstResponseId.key,
                            upstreamIndex: upstreamIndex
                        )
                        for responseId in transform.responseIds.dropFirst() {
                            self.sessionManager.removeUpstreamIdMapping(
                                sessionId: sessionIdCopy,
                                requestIdKey: responseId.key,
                                upstreamIndex: upstreamIndex
                            )
                        }
                    }
                    self.sendMCPError(
                        on: channel,
                        ids: transform.responseIds,
                        code: -32000,
                        message: "upstream timeout",
                        forceBatchArray: transform.isBatch,
                        prefersEventStream: prefersEventStream,
                        keepAlive: keepAlive,
                        sessionId: sessionIdCopy,
                        requestLog: requestLog
                    )
                }
            }
        } else {
            if transform.method == "notifications/initialized" && sessionManager.isInitialized() {
                sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
            } else {
                sessionManager.sendUpstream(transform.upstreamData, upstreamIndex: upstreamIndex)
                sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId, requestLog: requestLog)
            }
        }
    }

    private func sendSingleSSE(on channel: Channel, data: Data, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
        guard MCPResponseEmitter.sendSingleSSE(
            on: channel,
            data: data,
            keepAlive: keepAlive,
            sessionId: sessionId
        ) else {
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid upstream response",
                keepAlive: keepAlive,
                sessionId: sessionId,
                requestLog: requestLog
            )
            return
        }
        logResponse(requestLog, status: .ok, sessionId: sessionId)
    }

    private func rewriteUnsupportedResourcesListResponseIfNeeded(
        method: String?,
        originalId: RPCId?,
        upstreamData: Data
    ) -> Data {
        guard let method,
              method == "resources/list" || method == "resources/templates/list" else {
            return upstreamData
        }
        guard let originalId else { return upstreamData }

        let expectedKey = (method == "resources/list") ? "resources" : "resourceTemplates"

        guard let object = try? JSONSerialization.jsonObject(with: upstreamData, options: []) as? [String: Any] else {
            return upstreamData
        }

        let result = object["result"]

        // Happy path: upstream already returned a valid Resources result shape.
        if let resultObject = result as? [String: Any], resultObject[expectedKey] is [Any] {
            return upstreamData
        }

        // Only rewrite the standard JSON-RPC "Method not found" error (-32601).
        // Any other upstream error should pass through unchanged.
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? Int)
            guard code == -32601 else {
                return upstreamData
            }
            if let result,
               isNonStandardUnsupportedResourcesResult(result, method: method),
               let empty = emptyResourcesListResponseData(method: method, originalId: originalId) {
                return empty
            }
            return emptyResourcesListResponseData(method: method, originalId: originalId) ?? upstreamData
        }

        // Xcode MCP may return non-standard "tool-style" error payloads via `result`,
        // for example:
        //   {"result":{"content":[...],"isError":true}, ...}
        // Only rewrite this specific "unknown method" shape to avoid masking real errors.
        if let result,
           isNonStandardUnsupportedResourcesResult(result, method: method),
           let empty = emptyResourcesListResponseData(method: method, originalId: originalId) {
            return empty
        }

        return upstreamData
    }

    private func isNonStandardUnsupportedResourcesResult(_ result: Any, method: String) -> Bool {
        guard let resultObject = result as? [String: Any] else {
            return false
        }
        guard let isError = resultObject["isError"] as? Bool, isError else {
            return false
        }
        guard let content = resultObject["content"] as? [Any], !content.isEmpty else {
            return false
        }

        let methodToken = method.lowercased()
        for item in content {
            guard let contentObject = item as? [String: Any],
                  let text = contentObject["text"] as? String else {
                continue
            }
            let normalized = text.lowercased()
            if normalized.contains("unknown method"), normalized.contains(methodToken) {
                return true
            }
        }
        return false
    }

    private func emptyResourcesListResponseData(method: String, originalId: RPCId) -> Data? {
        let result: [String: Any] = (method == "resources/list")
            ? ["resources": [Any]()]
            : ["resourceTemplates": [Any]()]
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": originalId.value.foundationObject,
            "result": result,
        ]
        guard JSONSerialization.isValidJSONObject(response) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }

    private func sendJSON(on channel: Channel, buffer: ByteBuffer, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: .ok, sessionId: sessionId)
        MCPResponseEmitter.sendJSON(
            on: channel,
            buffer: buffer,
            keepAlive: keepAlive,
            sessionId: sessionId
        )
    }

    private func sendPlain(
        on channel: Channel,
        status: HTTPResponseStatus,
        body: String,
        keepAlive: Bool,
        sessionId: String?,
        requestLog: RequestLogContext
    ) {
        logResponse(requestLog, status: status, sessionId: sessionId)
        MCPResponseEmitter.sendPlain(
            on: channel,
            status: status,
            body: body,
            keepAlive: keepAlive,
            sessionId: sessionId
        )
    }

    private func sendEmpty(on channel: Channel, status: HTTPResponseStatus, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: status, sessionId: sessionId)
        MCPResponseEmitter.sendEmpty(
            on: channel,
            status: status,
            keepAlive: keepAlive,
            sessionId: sessionId
        )
    }

    private func sendMCPError(
        on channel: Channel,
        id: RPCId?,
        code: Int,
        message: String,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionId: String,
        requestLog: RequestLogContext
    ) {
        guard let data = MCPErrorResponder.errorResponseData(
            id: id,
            code: code,
            message: message
        ) else {
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid error response",
                keepAlive: keepAlive,
                sessionId: sessionId,
                requestLog: requestLog
            )
            return
        }
        if prefersEventStream {
            sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
        } else {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            sendJSON(on: channel, buffer: buffer, keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
        }
    }

    private func shouldNotifyUpstreamSuccess(for responseData: Data) -> Bool {
        guard let any = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return true
        }

        if let object = any as? [String: Any] {
            return isUpstreamOverloadedErrorResponse(object) == false
        }

        if let array = any as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            guard objects.isEmpty == false else {
                return true
            }
            return objects.allSatisfy(isUpstreamOverloadedErrorResponse) == false
        }

        return true
    }

    private func isUpstreamOverloadedErrorResponse(_ object: [String: Any]) -> Bool {
        guard let error = object["error"] as? [String: Any] else {
            return false
        }

        let code: Int?
        if let number = error["code"] as? NSNumber {
            code = number.intValue
        } else {
            code = error["code"] as? Int
        }
        guard code == -32002 else {
            return false
        }

        return (error["message"] as? String) == "upstream overloaded"
    }

    private func sendMCPError(
        on channel: Channel,
        ids: [RPCId],
        code: Int,
        message: String,
        forceBatchArray: Bool = false,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionId: String,
        requestLog: RequestLogContext
    ) {
        guard let data = MCPErrorResponder.errorResponseData(
            ids: ids,
            code: code,
            message: message,
            forceBatchArray: forceBatchArray
        ) else {
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid error response",
                keepAlive: keepAlive,
                sessionId: sessionId,
                requestLog: requestLog
            )
            return
        }
        if prefersEventStream {
            sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
        } else {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            sendJSON(on: channel, buffer: buffer, keepAlive: keepAlive, sessionId: sessionId, requestLog: requestLog)
        }
    }

    private func sendSSE(to channel: Channel, data: Data) {
        guard let payload = SSECodec.encodeDataEvent(data) else {
            logger.warning("Dropping non-UTF8 SSE payload", metadata: ["bytes": "\(data.count)"])
            return
        }
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            _ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
    }

    private func logRequest(_ request: RequestLogContext) {
        var metadata: Logger.Metadata = [
            "id": .string(request.id),
            "method": .string(request.method),
            "path": .string(request.path),
        ]
        if let remote = request.remoteAddress {
            metadata["remote"] = .string(remote)
        }
        logger.info("HTTP request", metadata: metadata)
    }

    private func logResponse(_ request: RequestLogContext, status: HTTPResponseStatus, sessionId: String?) {
        var metadata: Logger.Metadata = [
            "id": .string(request.id),
            "method": .string(request.method),
            "path": .string(request.path),
            "status": .string("\(status.code)"),
        ]
        if let remote = request.remoteAddress {
            metadata["remote"] = .string(remote)
        }
        if let sessionId {
            metadata["session"] = .string(sessionId)
        }
        logger.info("HTTP response", metadata: metadata)
    }

    private func remoteAddressString(for channel: Channel) -> String? {
        guard let address = channel.remoteAddress else {
            return nil
        }
        if let ip = address.ipAddress, let port = address.port {
            return "\(ip):\(port)"
        }
        return String(describing: address)
    }

}

struct RequestInfo {
    let expectsResponse: Bool
    let isBatch: Bool
    let idKey: String?
}

struct RequestTransform {
    let upstreamData: Data
    let expectsResponse: Bool
    let isBatch: Bool
    let idKey: String?
    let responseIds: [RPCId]
    let method: String?
    let originalId: RPCId?
    let isCacheableToolsListRequest: Bool
}

enum RequestInspector {
    static func transform(
        _ data: Data,
        sessionId: String,
        mapId: (_ sessionId: String, _ originalId: RPCId) -> Int64
    ) throws -> RequestTransform {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if var object = json as? [String: Any] {
            let method = object["method"] as? String
            // We intentionally treat tools/list as stable and cache it regardless of params.
            // Some clients attach pagination-like params even when they expect the full list.
            let isCacheableToolsListRequest = (method == "tools/list")
            if let id = object["id"], let rpcId = RPCId(any: id) {
                let upstreamId = mapId(sessionId, rpcId)
                object["id"] = upstreamId
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(
                    upstreamData: upstream,
                    expectsResponse: true,
                    isBatch: false,
                    idKey: rpcId.key,
                    responseIds: [rpcId],
                    method: method,
                    originalId: rpcId,
                    isCacheableToolsListRequest: isCacheableToolsListRequest
                )
            }
            let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: false,
                isBatch: false,
                idKey: nil,
                responseIds: [],
                method: method,
                originalId: nil,
                isCacheableToolsListRequest: isCacheableToolsListRequest
            )
        }

        if let array = json as? [Any] {
            var transformed: [Any] = []
            var responseIds: [RPCId] = []
            responseIds.reserveCapacity(array.count)
            for item in array {
                if var object = item as? [String: Any] {
                    if let id = object["id"], let rpcId = RPCId(any: id) {
                        let upstreamId = mapId(sessionId, rpcId)
                        object["id"] = upstreamId
                        responseIds.append(rpcId)
                    }
                    transformed.append(object)
                } else {
                    transformed.append(item)
                }
            }
            let upstream = try JSONSerialization.data(withJSONObject: transformed, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: !responseIds.isEmpty,
                isBatch: true,
                idKey: nil,
                responseIds: responseIds,
                method: nil,
                originalId: nil,
                isCacheableToolsListRequest: false
            )
        }

        return RequestTransform(
            upstreamData: data,
            expectsResponse: false,
            isBatch: false,
            idKey: nil,
            responseIds: [],
            method: nil,
            originalId: nil,
            isCacheableToolsListRequest: false
        )
    }
}
