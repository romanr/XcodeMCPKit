import Foundation
@preconcurrency import NIO
@preconcurrency import NIOHTTP1
@preconcurrency import NIOFoundationCompat

final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let config: ProxyConfig
    private let sessionManager: SessionManager

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var isSSE = false
    private var sseSessionId: String?
    private var bodyTooLarge = false

    init(config: ProxyConfig, sessionManager: SessionManager) {
        self.config = config
        self.sessionManager = sessionManager
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
            bodyTooLarge = false
        case .body(var buffer):
            guard var body = bodyBuffer, !bodyTooLarge else { return }
            if body.readableBytes + buffer.readableBytes > config.maxBodyBytes {
                bodyTooLarge = true
                bodyBuffer = body
                return
            }
            body.writeBuffer(&buffer)
            bodyBuffer = body
        case .end:
            handleRequest(context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let sessionId = sseSessionId {
            let session = sessionManager.session(id: sessionId)
            session.sseHub.remove(context.channel)
        }
    }

    private func handleRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else { return }
        requestHead = nil

        if bodyTooLarge {
            sendPlain(
                context: context,
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
            sendPlain(context: context, status: .ok, body: "ok", keepAlive: head.isKeepAlive, sessionId: nil)
        case (.GET, "/mcp"), (.GET, "/"), (.GET, "/mcp/events"), (.GET, "/events"):
            handleSSE(context: context, head: head)
        case (.DELETE, "/mcp"), (.DELETE, "/"):
            handleDelete(context: context, head: head)
        case (.POST, "/mcp"), (.POST, "/"):
            handlePost(context: context, head: head)
        default:
            sendPlain(context: context, status: .notFound, body: "not found", keepAlive: head.isKeepAlive, sessionId: nil)
        }
    }

    private func handleSSE(context: ChannelHandlerContext, head: HTTPRequestHead) {
        if isSSE {
            return
        }

        guard acceptsEventStream(head.headers) else {
            sendPlain(
                context: context,
                status: .notAcceptable,
                body: "client must accept text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        guard let sessionId = sessionIdFromHeaders(head.headers) else {
            sendPlain(
                context: context,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        guard sessionManager.hasSession(id: sessionId) else {
            sendPlain(
                context: context,
                status: .unauthorized,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionId: sessionId
            )
            return
        }

        let session = sessionManager.session(id: sessionId)
        let hadClients = session.sseHub.hasClients

        isSSE = true
        sseSessionId = sessionId
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
            sendPlain(
                context: context,
                status: .unauthorized,
                body: "session id required",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }
        guard sessionManager.hasSession(id: sessionId) else {
            sendPlain(
                context: context,
                status: .unauthorized,
                body: "session not found",
                keepAlive: head.isKeepAlive,
                sessionId: sessionId
            )
            return
        }
        sessionManager.removeSession(id: sessionId)
        sendEmpty(context: context, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId)
    }

    private func handlePost(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let wantsEventStream = acceptsEventStream(head.headers)
        let wantsJSON = acceptsJSON(head.headers)
        guard wantsEventStream || wantsJSON else {
            sendPlain(
                context: context,
                status: .notAcceptable,
                body: "client must accept application/json or text/event-stream",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        guard contentTypeIsJSON(head.headers) else {
            sendPlain(
                context: context,
                status: .unsupportedMediaType,
                body: "content-type must be application/json",
                keepAlive: head.isKeepAlive,
                sessionId: nil
            )
            return
        }

        guard var body = bodyBuffer else {
            sendPlain(context: context, status: .badRequest, body: "missing body", keepAlive: head.isKeepAlive, sessionId: nil)
            return
        }
        bodyBuffer = nil

        guard let bodyData = body.readData(length: body.readableBytes) else {
            sendPlain(context: context, status: .badRequest, body: "invalid body", keepAlive: head.isKeepAlive, sessionId: nil)
            return
        }

        let headerSessionId = sessionIdFromHeaders(head.headers)
        if let headerSessionId, !sessionManager.hasSession(id: headerSessionId) {
            sendPlain(
                context: context,
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
            guard let originalId = object["id"], !(originalId is NSNull) else {
                sendPlain(context: context, status: .badRequest, body: "missing id", keepAlive: head.isKeepAlive, sessionId: nil)
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
            future.whenComplete { [weak self, contextBox = ContextBox(context)] result in
                guard let self else { return }
                contextBox.context.eventLoop.execute {
                    switch result {
                    case .success(let buffer):
                        var buffer = buffer
                        guard let data = buffer.readData(length: buffer.readableBytes) else {
                            self.sendPlain(context: contextBox.context, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionId)
                            return
                        }
                        if prefersEventStream {
                            self.sendSingleSSE(context: contextBox.context, data: data, keepAlive: keepAlive, sessionId: sessionId)
                        } else {
                            var out = contextBox.context.channel.allocator.buffer(capacity: data.count)
                            out.writeBytes(data)
                            self.sendJSON(context: contextBox.context, buffer: out, keepAlive: keepAlive, sessionId: sessionId)
                        }
                    case .failure:
                        self.sendPlain(context: contextBox.context, status: .gatewayTimeout, body: "upstream timeout", keepAlive: keepAlive, sessionId: sessionId)
                    }
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
            sendPlain(context: context, status: .badRequest, body: "invalid json", keepAlive: head.isKeepAlive, sessionId: sessionId)
            return
        }

        if headerSessionId == nil {
            if transform.isBatch || transform.method != "initialize" || !transform.expectsResponse {
                sendPlain(
                    context: context,
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
                sendPlain(context: context, status: .badRequest, body: "missing id", keepAlive: head.isKeepAlive, sessionId: sessionId)
                return
            }

            sessionManager.upstream.send(transform.upstreamData)
            let contextBox = ContextBox(context)
            let keepAlive = head.isKeepAlive
            let sessionIdCopy = sessionId
            let prefersEventStream = wantsEventStream
            future.whenComplete { [weak self, contextBox] result in
                guard let self else { return }
                contextBox.context.eventLoop.execute {
                    switch result {
                    case .success(let buffer):
                        var buffer = buffer
                        guard let data = buffer.readData(length: buffer.readableBytes) else {
                            self.sendPlain(context: contextBox.context, status: .badGateway, body: "invalid upstream response", keepAlive: keepAlive, sessionId: sessionIdCopy)
                            return
                        }
                        if prefersEventStream {
                            self.sendSingleSSE(context: contextBox.context, data: data, keepAlive: keepAlive, sessionId: sessionIdCopy)
                        } else {
                            var out = contextBox.context.channel.allocator.buffer(capacity: data.count)
                            out.writeBytes(data)
                            self.sendJSON(context: contextBox.context, buffer: out, keepAlive: keepAlive, sessionId: sessionIdCopy)
                        }
                    case .failure:
                        self.sendPlain(context: contextBox.context, status: .gatewayTimeout, body: "upstream timeout", keepAlive: keepAlive, sessionId: sessionIdCopy)
                    }
                }
            }
        } else {
            if transform.method == "notifications/initialized" && sessionManager.isInitialized() {
                sendEmpty(context: context, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId)
            } else {
                sessionManager.upstream.send(transform.upstreamData)
                sendEmpty(context: context, status: .accepted, keepAlive: head.isKeepAlive, sessionId: sessionId)
            }
        }
    }

    private func sendSingleSSE(context: ChannelHandlerContext, data: Data, keepAlive: Bool, sessionId: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Mcp-Session-Id", value: sessionId)

        var head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        head.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: data.count + 16)
        buffer.writeString("data: ")
        buffer.writeBytes(data)
        buffer.writeString("\n\n")
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        if !keepAlive {
            context.close(promise: nil)
        }
    }

    private func sendJSON(context: ChannelHandlerContext, buffer: ByteBuffer, keepAlive: Bool, sessionId: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Mcp-Session-Id", value: sessionId)
        sendBuffer(context: context, status: .ok, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    private func sendPlain(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String, keepAlive: Bool, sessionId: String?) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        if let sessionId {
            headers.add(name: "Mcp-Session-Id", value: sessionId)
        }
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        sendBuffer(context: context, status: status, headers: headers, buffer: buffer, keepAlive: keepAlive)
    }

    private func sendEmpty(context: ChannelHandlerContext, status: HTTPResponseStatus, keepAlive: Bool, sessionId: String) {
        var headers = HTTPHeaders()
        headers.add(name: "Mcp-Session-Id", value: sessionId)
        sendBuffer(context: context, status: status, headers: headers, buffer: nil, keepAlive: keepAlive)
    }

    private func sendBuffer(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        buffer: ByteBuffer?,
        keepAlive: Bool
    ) {
        var head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        head.headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let buffer {
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        if !keepAlive {
            context.close(promise: nil)
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
        mapId: (_ sessionId: String, _ originalId: Any) -> Int64
    ) throws -> RequestTransform {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if var object = json as? [String: Any] {
            let method = object["method"] as? String
            if let id = object["id"], !(id is NSNull) {
                let upstreamId = mapId(sessionId, id)
                object["id"] = upstreamId
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(
                    upstreamData: upstream,
                    expectsResponse: true,
                    isBatch: false,
                    idKey: idKey(from: id),
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
                    if let id = object["id"], !(id is NSNull) {
                        let upstreamId = mapId(sessionId, id)
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

    private static func idKey(from value: Any) -> String {
        if let stringId = value as? String {
            return stringId
        }
        if let numberId = value as? NSNumber {
            return numberId.stringValue
        }
        return String(describing: value)
    }
}

private struct ContextBox: @unchecked Sendable {
    let context: ChannelHandlerContext

    init(_ context: ChannelHandlerContext) {
        self.context = context
    }
}
