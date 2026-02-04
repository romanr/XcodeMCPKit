import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat
import NIOConcurrencyHelpers

final class HTTPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private struct State: Sendable {
        var requestHead: HTTPRequestHead?
        var bodyBuffer: ByteBuffer?
        var isSSE = false
        var sseSessionId: String?
        var bodyTooLarge = false
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig
    private let sessionManager: SessionManager

    init(config: ProxyConfig, sessionManager: SessionManager) {
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

    func channelInactive(context: ChannelHandlerContext) {
        let sessionId = state.withLockedValue { $0.sseSessionId }
        if let sessionId {
            let session = sessionManager.session(id: sessionId)
            session.sseHub.remove(context.channel)
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        let head = state.withLockedValue { state -> HTTPRequestHead? in
            let head = state.requestHead
            state.requestHead = nil
            return head
        }
        guard let head else { return }

        let bodyTooLarge = state.withLockedValue { $0.bodyTooLarge }
        if bodyTooLarge {
            Self.sendPlain(
                on: context.channel,
                status: .payloadTooLarge,
                body: "request body too large",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        let path = head.uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? head.uri
        switch (head.method, path) {
        case (.GET, "/health"):
            Self.sendPlain(on: context.channel, status: .ok, body: "ok", keepAlive: head.isKeepAlive, sessionId: nil)
        case (.GET, "/mcp"), (.GET, "/"), (.GET, "/mcp/events"), (.GET, "/events"):
            handleSSE(context: context, head: head)
        case (.DELETE, "/mcp"), (.DELETE, "/"):
            handleDelete(context: context, head: head)
        case (.POST, "/mcp"), (.POST, "/"):
            handlePost(context: context, head: head)
        default:
            Self.sendPlain(on: context.channel, status: .notFound, body: "not found", keepAlive: head.isKeepAlive, sessionId: nil)
        }
    }

    private func handleSSE(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let alreadySSE = state.withLockedValue { $0.isSSE }
        if alreadySSE {
            return
        }

        guard acceptsEventStream(head.headers) else {
            Self.sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        guard let sessionId = sessionIdFromHeaders(head.headers) else {
            Self.sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        guard sessionManager.hasSession(id: sessionId) else {
            Self.sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionId: sessionId
            )
            return
        }

        let session = sessionManager.session(id: sessionId)
        let hadClients = session.sseHub.hasClients

        state.withLockedValue { state in
            state.isSSE = true
            state.sseSessionId = sessionId
        }
        session.sseHub.add(context.channel)

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "Mcp-Session-Id", value: sessionId)

        let responseHead = HTTPResponseHead(version: head.version, status: .ok, headers: headers)
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
    }

    private func handleDelete(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard let sessionId = sessionIdFromHeaders(head.headers) else {
            Self.sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }
        guard sessionManager.hasSession(id: sessionId) else {
            Self.sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionId: sessionId
            )
            return
        }
        sessionManager.removeSession(id: sessionId)
        Self.sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId)
    }

    private func handlePost(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let wantsEventStream = acceptsEventStream(head.headers)
        let wantsJSON = acceptsJSON(head.headers)
        guard wantsEventStream || wantsJSON else {
            Self.sendPlain(
                on: context.channel,
                status: .notAcceptable,
                body: "client must accept application/json or text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        guard contentTypeIsJSON(head.headers) else {
            Self.sendPlain(
                on: context.channel,
                status: .unsupportedMediaType,
                body: "content-type must be application/json",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        let body = state.withLockedValue { state -> ByteBuffer? in
            let body = state.bodyBuffer
            state.bodyBuffer = nil
            return body
        }
        guard var body = body else {
            Self.sendPlain(on: context.channel, status: .badRequest, body: "missing body", keepAlive: head.isKeepAlive, sessionId: nil)
            return
        }

        guard let bodyData = body.readData(length: body.readableBytes) else {
            Self.sendPlain(on: context.channel, status: .badRequest, body: "invalid body", keepAlive: head.isKeepAlive, sessionId: nil)
            return
        }

        let headerSessionId = sessionIdFromHeaders(head.headers)
        if let headerSessionId, !sessionManager.hasSession(id: headerSessionId) {
            Self.sendPlain(
                on: context.channel,
                status: .unauthorized,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionId: headerSessionId
            )
            return
        }

        if let object = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any],
           let method = object["method"] as? String,
           method == "initialize",
           headerSessionId == nil {
            guard let originalIdValue = object["id"], let originalId = RPCId(any: originalIdValue) else {
                Self.sendPlain(on: context.channel, status: .badRequest, body: "missing id", keepAlive: head.isKeepAlive, sessionId: nil)
                return
            }
            let sessionId = UUID().uuidString
            _ = sessionManager.session(id: sessionId)
            let future = sessionManager.registerInitialize(
                originalId: originalId,
                requestObject: object,
                on: context.eventLoop
            )
            let keepAlive = head.isKeepAlive
            let prefersEventStream = wantsEventStream
            let channel = context.channel
            future.whenComplete { result in
                switch result {
                case .success(let buffer):
                    var buffer = buffer
                    guard let data = buffer.readData(length: buffer.readableBytes) else {
                        Self.sendPlain(on: channel, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionId)
                        return
                    }
                    if prefersEventStream {
                        Self.sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionId: sessionId)
                    } else {
                        var out = channel.allocator.buffer(capacity: data.count)
                        out.writeBytes(data)
                        Self.sendJSON(on: channel, buffer: out, keepAlive: keepAlive, sessionId: sessionId)
                    }
                case .failure:
                    Self.sendPlain(on: channel, status: .gatewayTimeout, body: "upstream timeout", keepAlive: keepAlive, sessionId: sessionId)
                }
            }
            return
        }

        let sessionId = headerSessionId ?? UUID().uuidString

        let transform: RequestTransform
        do {
            transform = try RequestInspector.transform(
                bodyData,
                sessionId: sessionId,
                mapId: { sessionId, originalId in
                    sessionManager.assignUpstreamId(sessionId: sessionId, originalId: originalId)
                }
            )
        } catch {
            Self.sendPlain(on: context.channel, status: .badRequest, body: "invalid json", keepAlive: head.isKeepAlive, sessionId: sessionId)
            return
        }

        if headerSessionId == nil {
            if transform.isBatch || transform.method != "initialize" || !transform.expectsResponse {
                Self.sendPlain(
                    on: context.channel,
                    status: .unprocessableEntity,
                    body: "expected initialize request",
                    keepAlive: head.isKeepAlive,
                    sessionId: sessionId
                )
                return
            }
        }

        let session = sessionManager.session(id: sessionId)

        if transform.expectsResponse {
            let future: EventLoopFuture<ByteBuffer>
            if transform.isBatch {
                future = session.router.registerBatch(on: context.eventLoop)
            } else if let idKey = transform.idKey {
                future = session.router.registerRequest(idKey: idKey, on: context.eventLoop)
            } else {
                Self.sendPlain(on: context.channel, status: .badRequest, body: "missing id", keepAlive: head.isKeepAlive, sessionId: sessionId)
                return
            }

            sessionManager.sendUpstream(transform.upstreamData)
            let keepAlive = head.isKeepAlive
            let sessionIdCopy = sessionId
            let prefersEventStream = wantsEventStream
            let channel = context.channel
            future.whenComplete { result in
                switch result {
                case .success(let buffer):
                    var buffer = buffer
                    guard let data = buffer.readData(length: buffer.readableBytes) else {
                        Self.sendPlain(on: channel, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionIdCopy)
                        return
                    }
                    if prefersEventStream {
                        Self.sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionId: sessionIdCopy)
                    } else {
                        var out = channel.allocator.buffer(capacity: data.count)
                        out.writeBytes(data)
                        Self.sendJSON(on: channel, buffer: out, keepAlive: keepAlive, sessionId: sessionIdCopy)
                    }
                case .failure:
                    Self.sendPlain(on: channel, status: .gatewayTimeout, body: "upstream timeout", keepAlive: keepAlive, sessionId: sessionIdCopy)
                }
            }
        } else {
            if transform.method == "notifications/initialized" && sessionManager.isInitialized() {
                Self.sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId)
            } else {
                sessionManager.sendUpstream(transform.upstreamData)
                Self.sendEmpty(on: context.channel, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId)
            }
        }
    }

    private static func sendSingleSSE(on channel: Channel, data: Data, keepAlive: Bool, sessionId: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Mcp-Session-Id", value: sessionId)

        var head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        head.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        channel.write(HTTPServerResponsePart.head(head), promise: nil)

        var buffer = channel.allocator.buffer(capacity: data.count + 16)
        buffer.writeString("data: ")
        buffer.writeBytes(data)
        buffer.writeString("\n\n")
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        if !keepAlive {
            channel.close(promise: nil)
        }
    }

    private static func sendJSON(on channel: Channel, buffer: ByteBuffer, keepAlive: Bool, sessionId: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Mcp-Session-Id", value: sessionId)
        sendBuffer(on: channel, status: .ok, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    private static func sendPlain(on channel: Channel, status: HTTPResponseStatus, body: String, keepAlive: Bool, sessionId: String?) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        if let sessionId {
            headers.add(name: "Mcp-Session-Id", value: sessionId)
        }
        var buffer = channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        sendBuffer(on: channel, status: status, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    private static func sendEmpty(on channel: Channel, status: HTTPResponseStatus, keepAlive: Bool, sessionId: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Mcp-Session-Id", value: sessionId)
        sendBuffer(on: channel, status: status, headers: headers, buffer: nil, keepAlive: keepAlive)
    }

    private static func sendBuffer(
        on channel: Channel,
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        buffer: ByteBuffer?,
        keepAlive: Bool
    ) {
        var head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        head.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if let buffer {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        if !keepAlive {
            channel.close(promise: nil)
        }
    }

    private func sendSSE(to channel: Channel, data: Data) {
        let payload = "data: \(String(decoding: data, as: UTF8.self))\n\n"
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            _ = channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)))
        }
    }

    private func sessionIdFromHeaders(_ headers: HTTPHeaders) -> String? {
        headers.first(name: "Mcp-Session-Id")
    }

    private func acceptsEventStream(_ headers: HTTPHeaders) -> Bool {
        guard let accept = headers.first(name: "Accept")?.lowercased() else { return false }
        return accept.contains("text/event-stream")
    }

    private func acceptsJSON(_ headers: HTTPHeaders) -> Bool {
        guard let accept = headers.first(name: "Accept")?.lowercased() else { return true }
        return accept.contains("application/json") || accept.contains("*/*")
    }

    private func contentTypeIsJSON(_ headers: HTTPHeaders) -> Bool {
        guard let contentType = headers.first(name: "Content-Type")?.lowercased() else { return false }
        return contentType.hasPrefix("application/json")
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
    let method: String?
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
            if let id = object["id"], let rpcId = RPCId(any: id) {
                let upstreamId = mapId(sessionId, rpcId)
                object["id"] = upstreamId
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(
                    upstreamData: upstream,
                    expectsResponse: true,
                    isBatch: false,
                    idKey: rpcId.key,
                    method: method
                )
            }
            let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: false,
                isBatch: false,
                idKey: nil,
                method: method
            )
        }

        if let array = json as? [Any] {
            var transformed: [Any] = []
            var hasRequest = false
            for item in array {
                if var object = item as? [String: Any] {
                    if let id = object["id"], let rpcId = RPCId(any: id) {
                        let upstreamId = mapId(sessionId, rpcId)
                        object["id"] = upstreamId
                        hasRequest = true
                    }
                    transformed.append(object)
                } else {
                    transformed.append(item)
                }
            }
            let upstream = try JSONSerialization.data(withJSONObject: transformed, options: [])
            return RequestTransform(
                upstreamData: upstream,
                expectsResponse: hasRequest,
                isBatch: true,
                idKey: nil,
                method: nil
            )
        }

        return RequestTransform(
            upstreamData: data,
            expectsResponse: false,
            isBatch: false,
            idKey: nil,
            method: nil
        )
    }
}
