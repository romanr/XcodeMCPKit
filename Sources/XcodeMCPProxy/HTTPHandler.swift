import Foundation
import NIO
import NIOHTTP1
import NIOFoundationCompat

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
        let wantsEventStream = acceptsEventStream(head.headers)
        if head.method == .GET, wantsEventStream {
            handleSSE(context: context, head: head)
            return
        }
        switch (head.method, path) {
        case (.GET, "/health"):
            sendPlain(context: context, status: .ok, body: "ok", keepAlive: head.isKeepAlive, sessionId: nil)
        case (.GET, "/mcp/events"), (.GET, "/events"):
            handleSSE(context: context, head: head)
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

        let sessionId = sessionIdFromHeaders(head.headers) ?? UUID().uuidString
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

    private func handlePost(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard var body = bodyBuffer else {
            sendPlain(context: context, status: .badRequest, body: "missing body", keepAlive: head.isKeepAlive, sessionId: nil)
            return
        }
        bodyBuffer = nil

        guard let bodyData = body.readData(length: body.readableBytes) else {
            sendPlain(context: context, status: .badRequest, body: "invalid body", keepAlive: head.isKeepAlive, sessionId: nil)
            return
        }

        let sessionId = sessionIdFromHeaders(head.headers) ?? UUID().uuidString
        let session = sessionManager.session(id: sessionId)

        let transform: RequestTransform
        do {
            transform = try RequestInspector.transform(bodyData, sessionId: sessionId)
        } catch {
            sendPlain(context: context, status: .badRequest, body: "invalid json", keepAlive: head.isKeepAlive, sessionId: sessionId)
            return
        }

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
            future.whenComplete { [weak self, weak context] result in
                guard let self, let context else { return }
                context.eventLoop.execute {
                    switch result {
                    case .success(let buffer):
                        let rewritten = ResponseRewriter.rewrite(buffer: buffer, sessionId: sessionId)
                        self.sendJSON(context: context, buffer: rewritten, keepAlive: head.isKeepAlive, sessionId: sessionId)
                    case .failure:
                        self.sendPlain(context: context, status: .gatewayTimeout, body: "upstream timeout", keepAlive: head.isKeepAlive, sessionId: sessionId)
                    }
                }
            }
        } else {
            sessionManager.upstream.send(transform.upstreamData)
            sendEmpty(context: context, status: .noContent, keepAlive: head.isKeepAlive, sessionId: sessionId)
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
}

enum RequestInspector {
    static func transform(_ data: Data, sessionId: String) throws -> RequestTransform {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        if var object = json as? [String: Any] {
            if let id = object["id"], !(id is NSNull) {
                let prefixed = IdCodec.encode(sessionId: sessionId, originalId: id)
                object["id"] = prefixed
                let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
                return RequestTransform(upstreamData: upstream, expectsResponse: true, isBatch: false, idKey: prefixed)
            }
            let upstream = try JSONSerialization.data(withJSONObject: object, options: [])
            return RequestTransform(upstreamData: upstream, expectsResponse: false, isBatch: false, idKey: nil)
        }

        if let array = json as? [Any] {
            var transformed: [Any] = []
            var hasRequest = false
            for item in array {
                if var object = item as? [String: Any] {
                    if let id = object["id"], !(id is NSNull) {
                        let prefixed = IdCodec.encode(sessionId: sessionId, originalId: id)
                        object["id"] = prefixed
                        hasRequest = true
                    }
                    transformed.append(object)
                } else {
                    transformed.append(item)
                }
            }
            let upstream = try JSONSerialization.data(withJSONObject: transformed, options: [])
            return RequestTransform(upstreamData: upstream, expectsResponse: hasRequest, isBatch: true, idKey: nil)
        }

        return RequestTransform(upstreamData: data, expectsResponse: false, isBatch: false, idKey: nil)
    }
}

enum ResponseRewriter {
    static func rewrite(buffer: ByteBuffer, sessionId: String) -> ByteBuffer {
        var buffer = buffer
        guard let data = buffer.readData(length: buffer.readableBytes) else { return buffer }
        let rewritten = rewrite(data: data, sessionId: sessionId)
        var out = ByteBufferAllocator().buffer(capacity: rewritten.count)
        out.writeBytes(rewritten)
        return out
    }

    static func rewrite(data: Data, sessionId: String) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else { return data }
        if var object = json as? [String: Any] {
            if let rewrittenId = IdCodec.stripPrefix(sessionId: sessionId, id: object["id"]) {
                object["id"] = rewrittenId
            }
            return (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? data
        }
        if let array = json as? [Any] {
            let transformed = array.map { item -> Any in
                guard var object = item as? [String: Any] else { return item }
                if let rewrittenId = IdCodec.stripPrefix(sessionId: sessionId, id: object["id"]) {
                    object["id"] = rewrittenId
                }
                return object
            }
            return (try? JSONSerialization.data(withJSONObject: transformed, options: [])) ?? data
        }
        return data
    }
}
