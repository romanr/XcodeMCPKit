import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import NIOConcurrencyHelpers
import ProxyCore
import ProxyRuntime
import ProxyFeatureXcode

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
    package let sessionManager: any RuntimeCoordinating
    package let postService: HTTPPostService
    package let responseWriter: HTTPResponseWriter
    package let logger: Logger = ProxyLogging.make("http")

    package init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        warmupDriver: XcodeEditorWarmupDriver = XcodeEditorWarmupDriver()
    ) {
        self.config = config
        self.sessionManager = sessionManager
        self.postService = HTTPPostService(
            config: config,
            sessionManager: sessionManager,
            refreshCodeIssuesCoordinator: refreshCodeIssuesCoordinator,
            warmupDriver: warmupDriver,
            logger: ProxyLogging.make("http")
        )
        self.responseWriter = HTTPResponseWriter(logger: ProxyLogging.make("http.response"))
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
        headers.add(name: "Mcp-Session-Id", value: sessionID)

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
        let keepAlive = head.isKeepAlive
        let channel = context.channel
        postService.handle(
            bodyData: bodyData,
            headerSessionID: headerSessionID,
            headerSessionExists: headerSessionExists,
            prefersEventStream: prefersEventStream,
            eventLoop: context.eventLoop
        ).whenSuccess { resolution in
            self.sendPostResolution(
                resolution,
                on: channel,
                keepAlive: keepAlive,
                requestLog: requestLog
            )
        }
    }

}
