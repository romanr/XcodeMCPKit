import Foundation
import Logging
import NIO
import NIOHTTP1
import ProxyCore

extension HTTPHandler {
    func handleLocalPostHandling(
        _ handling: LocalPostHandling,
        on channel: Channel,
        prefersEventStream: Bool,
        keepAlive: Bool,
        requestLog: RequestLogContext
    ) {
        switch handling {
        case .initialize(let future, let sessionID, let originalID):
            future.whenComplete { result in
                switch result {
                case .success(let buffer):
                    var buffer = buffer
                    guard let data = buffer.readData(length: buffer.readableBytes) else {
                        self.sendPlain(
                            on: channel,
                            status: .badGateway,
                            body: "invalid upstream response",
                            keepAlive: keepAlive,
                            sessionID: sessionID,
                            requestLog: requestLog
                        )
                        return
                    }
                    if prefersEventStream {
                        self.sendSingleSSE(
                            on: channel,
                            data: data,
                            keepAlive: keepAlive,
                            sessionID: sessionID,
                            requestLog: requestLog
                        )
                    } else {
                        var out = channel.allocator.buffer(capacity: data.count)
                        out.writeBytes(data)
                        self.sendJSON(
                            on: channel,
                            buffer: out,
                            keepAlive: keepAlive,
                            sessionID: sessionID,
                            requestLog: requestLog
                        )
                    }
                case .failure:
                    self.sendMCPError(
                        on: channel,
                        id: originalID,
                        code: -32000,
                        message: "upstream timeout",
                        prefersEventStream: prefersEventStream,
                        keepAlive: keepAlive,
                        sessionID: sessionID,
                        requestLog: requestLog
                    )
                }
            }
        case .immediateResponse(let data, let sessionID):
            if prefersEventStream {
                sendSingleSSE(
                    on: channel,
                    data: data,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            } else {
                var out = channel.allocator.buffer(capacity: data.count)
                out.writeBytes(data)
                sendJSON(
                    on: channel,
                    buffer: out,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            }
        case .mcpError(let id, let code, let message, let sessionID):
            sendMCPError(
                on: channel,
                id: id,
                code: code,
                message: message,
                prefersEventStream: prefersEventStream,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        }
    }

    func sendSingleSSE(on channel: Channel, data: Data, keepAlive: Bool, sessionID: String, requestLog: RequestLogContext) {
        guard MCPResponseEmitter.sendSingleSSE(
            on: channel,
            data: data,
            keepAlive: keepAlive,
            sessionID: sessionID
        ) else {
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid upstream response",
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }
        logResponse(requestLog, status: .ok, sessionID: sessionID)
    }

    func sendJSON(on channel: Channel, buffer: ByteBuffer, keepAlive: Bool, sessionID: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: .ok, sessionID: sessionID)
        MCPResponseEmitter.sendJSON(
            on: channel,
            buffer: buffer,
            keepAlive: keepAlive,
            sessionID: sessionID
        )
    }

    func sendJSONData(
        on channel: Channel,
        data: Data,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: RequestLogContext
    ) {
        logResponse(requestLog, status: .ok, sessionID: sessionID)
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        MCPResponseEmitter.sendJSON(
            on: channel,
            buffer: buffer,
            keepAlive: keepAlive,
            sessionID: sessionID
        )
    }

    func sendPlain(
        on channel: Channel,
        status: HTTPResponseStatus,
        body: String,
        keepAlive: Bool,
        sessionID: String?,
        requestLog: RequestLogContext
    ) {
        logResponse(requestLog, status: status, sessionID: sessionID)
        MCPResponseEmitter.sendPlain(
            on: channel,
            status: status,
            body: body,
            keepAlive: keepAlive,
            sessionID: sessionID
        )
    }

    func sendEmpty(on channel: Channel, status: HTTPResponseStatus, keepAlive: Bool, sessionID: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: status, sessionID: sessionID)
        MCPResponseEmitter.sendEmpty(
            on: channel,
            status: status,
            keepAlive: keepAlive,
            sessionID: sessionID
        )
    }

    func sendMCPError(
        on channel: Channel,
        id: RPCID?,
        code: Int,
        message: String,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
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
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }
        if prefersEventStream {
            sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionID: sessionID, requestLog: requestLog)
        } else {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            sendJSON(on: channel, buffer: buffer, keepAlive: keepAlive, sessionID: sessionID, requestLog: requestLog)
        }
    }

    func sendMCPError(
        on channel: Channel,
        ids: [RPCID],
        code: Int,
        message: String,
        forceBatchArray: Bool = false,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
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
                sessionID: sessionID,
                requestLog: requestLog
            )
            return
        }
        if prefersEventStream {
            sendSingleSSE(on: channel, data: data, keepAlive: keepAlive, sessionID: sessionID, requestLog: requestLog)
        } else {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            sendJSON(on: channel, buffer: buffer, keepAlive: keepAlive, sessionID: sessionID, requestLog: requestLog)
        }
    }

    func sendSSE(to channel: Channel, data: Data) {
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

    func logRequest(_ request: RequestLogContext) {
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

    func logResponse(_ request: RequestLogContext, status: HTTPResponseStatus, sessionID: String?) {
        var metadata: Logger.Metadata = [
            "id": .string(request.id),
            "method": .string(request.method),
            "path": .string(request.path),
            "status": .string("\(status.code)"),
        ]
        if let remote = request.remoteAddress {
            metadata["remote"] = .string(remote)
        }
        if let sessionID {
            metadata["session"] = .string(sessionID)
        }
        logger.info("HTTP response", metadata: metadata)
    }

    func remoteAddressString(for channel: Channel) -> String? {
        guard let address = channel.remoteAddress else {
            return nil
        }
        if let ip = address.ipAddress, let port = address.port {
            return "\(ip):\(port)"
        }
        return String(describing: address)
    }

    var isLoopbackDebugEndpointEnabled: Bool {
        switch config.listenHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }
}
