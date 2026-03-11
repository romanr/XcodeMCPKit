import Foundation
import Logging
import NIO
import NIOHTTP1
import XcodeMCPProxyCore

extension HTTPHandler {
    func sendSingleSSE(on channel: Channel, data: Data, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
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

    func rewriteUnsupportedResourcesListResponseIfNeeded(
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

        if let resultObject = result as? [String: Any], resultObject[expectedKey] is [Any] {
            return upstreamData
        }

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

        if let result,
           isNonStandardUnsupportedResourcesResult(result, method: method),
           let empty = emptyResourcesListResponseData(method: method, originalId: originalId) {
            return empty
        }

        return upstreamData
    }

    func isNonStandardUnsupportedResourcesResult(_ result: Any, method: String) -> Bool {
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

    func emptyResourcesListResponseData(method: String, originalId: RPCId) -> Data? {
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

    func sendJSON(on channel: Channel, buffer: ByteBuffer, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: .ok, sessionId: sessionId)
        MCPResponseEmitter.sendJSON(
            on: channel,
            buffer: buffer,
            keepAlive: keepAlive,
            sessionId: sessionId
        )
    }

    func sendJSONData(
        on channel: Channel,
        data: Data,
        keepAlive: Bool,
        sessionId: String?,
        requestLog: RequestLogContext
    ) {
        logResponse(requestLog, status: .ok, sessionId: sessionId)
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        MCPResponseEmitter.sendJSON(
            on: channel,
            buffer: buffer,
            keepAlive: keepAlive,
            sessionId: sessionId
        )
    }

    func sendPlain(
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

    func sendEmpty(on channel: Channel, status: HTTPResponseStatus, keepAlive: Bool, sessionId: String, requestLog: RequestLogContext) {
        logResponse(requestLog, status: status, sessionId: sessionId)
        MCPResponseEmitter.sendEmpty(
            on: channel,
            status: status,
            keepAlive: keepAlive,
            sessionId: sessionId
        )
    }

    func sendMCPError(
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

    func shouldNotifyUpstreamSuccess(for responseData: Data) -> Bool {
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

    func isRetryableRefreshCodeIssuesFailure(_ responseData: Data) -> Bool {
        let retryableErrorText = "SourceEditorCallableDiagnosticError error 5"
        guard
            let object = try? JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
            let result = object["result"] as? [String: Any],
            let isError = result["isError"] as? Bool,
            isError,
            let content = result["content"] as? [Any]
        else {
            return false
        }

        for item in content {
            guard let contentObject = item as? [String: Any],
                let text = contentObject["text"] as? String
            else {
                continue
            }
            if text.contains("Failed to retrieve diagnostics for"),
                text.contains(retryableErrorText)
            {
                return true
            }
        }
        return false
    }

    func isUpstreamOverloadedErrorResponse(_ object: [String: Any]) -> Bool {
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

    func sendMCPError(
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

    func logResponse(_ request: RequestLogContext, status: HTTPResponseStatus, sessionId: String?) {
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
