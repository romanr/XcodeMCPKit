import Foundation
import Logging
import NIO
import ProxyCore
import ProxySession

package enum LocalPostHandling {
    case initialize(
        future: EventLoopFuture<ByteBuffer>,
        sessionId: String,
        originalId: RPCId
    )
    case immediateResponse(data: Data, sessionId: String)
    case mcpError(id: RPCId?, code: Int, message: String, sessionId: String)
}

package struct LocalMCPResponder {
    private let sessionManager: any SessionManaging
    private let logger: Logger

    package init(sessionManager: any SessionManaging, logger: Logger) {
        self.sessionManager = sessionManager
        self.logger = logger
    }

    package func handle(
        object: [String: Any],
        headerSessionId: String?,
        headerSessionExists: Bool,
        eventLoop: EventLoop
    ) -> LocalPostHandling? {
        guard let method = object["method"] as? String else {
            return nil
        }

        if method == "initialize" {
            guard let originalIdValue = object["id"], let originalId = RPCId(any: originalIdValue) else {
                return .mcpError(
                    id: nil,
                    code: -32600,
                    message: "missing id",
                    sessionId: headerSessionId ?? UUID().uuidString
                )
            }
            let sessionId = headerSessionId ?? UUID().uuidString
            _ = sessionManager.session(id: sessionId)
            let future = sessionManager.registerInitialize(
                sessionId: sessionId,
                originalId: originalId,
                requestObject: object,
                on: eventLoop
            )
            return .initialize(
                future: future,
                sessionId: sessionId,
                originalId: originalId
            )
        }

        if (method == "resources/list" || method == "resources/templates/list") && sessionManager.isInitialized() == false {
            guard let originalIdValue = object["id"], let originalId = RPCId(any: originalIdValue) else {
                return .mcpError(
                    id: nil,
                    code: -32600,
                    message: "missing id",
                    sessionId: headerSessionId ?? UUID().uuidString
                )
            }

            let sessionId = headerSessionId ?? UUID().uuidString
            if let headerSessionId, headerSessionExists == false {
                _ = sessionManager.session(id: headerSessionId)
            }

            let result: [String: Any] = (method == "resources/list")
                ? ["resources": [Any]()]
                : ["resourceTemplates": [Any]()]
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalId.value.foundationObject,
                "result": result,
            ]
            guard JSONSerialization.isValidJSONObject(response),
                let data = try? JSONSerialization.data(withJSONObject: response, options: [])
            else {
                return nil
            }
            return .immediateResponse(data: data, sessionId: sessionId)
        }

        if method == "tools/list",
            let headerSessionId,
            sessionManager.isInitialized(),
            let cachedResult = sessionManager.cachedToolsListResult(),
            let originalIdValue = object["id"],
            let originalId = RPCId(any: originalIdValue)
        {
            if headerSessionExists == false {
                _ = sessionManager.session(id: headerSessionId)
            }
            let hasParams: Bool = {
                guard let params = object["params"] else { return false }
                return !(params is NSNull)
            }()
            let pinnedUpstreamIndex = sessionManager.chooseUpstreamIndex(
                sessionId: headerSessionId,
                shouldPin: true
            )
            logger.debug(
                "tools/list cache hit",
                metadata: [
                    "session": .string(headerSessionId),
                    "has_params": .string(hasParams ? "true" : "false"),
                    "pinned_upstream": .string(pinnedUpstreamIndex.map(String.init) ?? "none"),
                ]
            )
            let response: [String: Any] = [
                "jsonrpc": "2.0",
                "id": originalId.value.foundationObject,
                "result": cachedResult.foundationObject,
            ]
            guard JSONSerialization.isValidJSONObject(response),
                let data = try? JSONSerialization.data(withJSONObject: response, options: [])
            else {
                return nil
            }
            return .immediateResponse(data: data, sessionId: headerSessionId)
        }

        return nil
    }
}
