import Foundation
import NIO
import NIOFoundationCompat
import NIOHTTP1
import ProxyCore
import ProxyRuntime
import ProxyFeatureXcode

extension HTTPHandler {
    func refreshCodeIssuesRequest(from requestJSON: Any) -> RefreshCodeIssuesRequest? {
        guard let object = requestJSON as? [String: Any],
            let method = object["method"] as? String,
            method == "tools/call",
            let params = object["params"] as? [String: Any],
            let toolName = params["name"] as? String,
            toolName == RefreshCodeIssuesRequest.toolName
        else {
            return nil
        }

        let arguments = params["arguments"] as? [String: Any]
        let tabIdentifier = arguments?["tabIdentifier"] as? String
        let filePath = arguments?["filePath"] as? String
        return RefreshCodeIssuesRequest(tabIdentifier: tabIdentifier, filePath: filePath)
    }

    func callInternalTool(
        name: String,
        arguments: [String: Any],
        sessionID: String,
        eventLoop: EventLoop
    ) async -> [String: Any]? {
        await forwardingService.callInternalTool(
            name: name,
            arguments: arguments,
            sessionID: sessionID,
            eventLoop: eventLoop
        )
    }

    func listXcodeWindows(
        sessionID: String,
        eventLoop: EventLoop
    ) async -> [XcodeWindowInfo]? {
        await windowQueryService.listWindows(
            sessionID: sessionID,
            eventLoop: eventLoop,
            toolCaller: { name, arguments, sessionID, eventLoop in
                await self.callInternalTool(
                    name: name,
                    arguments: arguments,
                    sessionID: sessionID,
                    eventLoop: eventLoop
                )
            }
        )
    }

    func forwardOnce(
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop
    ) async -> RefreshForwardAttemptResult {
        let parsedRequestJSON: Any
        do {
            parsedRequestJSON = try JSONSerialization.jsonObject(with: bodyData, options: [])
        } catch {
            return .invalidRequest
        }

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                sessionID: sessionID
            ) else {
                return .upstreamUnavailable(
                    responseIDs: requestIDs,
                    isBatch: requestIsBatch
                )
            }
            prepared = candidate
        } catch {
            return .invalidRequest
        }

        let session = sessionManager.session(id: sessionID)
        let started: MCPForwardingService.StartedRequest
        do {
            started = try forwardingService.startRequest(
                prepared,
                session: session,
                on: eventLoop
            )
        } catch {
            return .invalidRequest
        }

        let resolution: MCPForwardingService.ResponseResolution
        do {
            let buffer = try await started.future.get()
            resolution = forwardingService.resolveResponse(
                .success(buffer),
                started: started,
                sessionID: sessionID
            )
        } catch {
            resolution = forwardingService.resolveResponse(
                .failure(error),
                started: started,
                sessionID: sessionID
            )
        }

        switch resolution {
        case .success(let responseData):
            return .success(responseData)
        case .timeout:
            return .timeout(
                responseIDs: started.transform.responseIDs,
                isBatch: started.transform.isBatch
            )
        case .invalidUpstreamResponse:
            return .invalidUpstreamResponse
        }
    }

    func forwardRefreshCodeIssuesRequest(
        _ refreshRequest: RefreshCodeIssuesRequest,
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop
    ) async -> RefreshForwardAttemptResult {
        await refreshWorkflow.run(
            refreshRequest: refreshRequest,
            bodyData: bodyData,
            sessionID: sessionID,
            requestIDs: requestIDs,
            requestIsBatch: requestIsBatch,
            eventLoop: eventLoop,
            windowsProvider: { sessionID, eventLoop in
                await self.listXcodeWindows(sessionID: sessionID, eventLoop: eventLoop)
            },
            forwarder: { bodyData, sessionID, requestIDs, requestIsBatch, eventLoop in
                await self.forwardOnce(
                    bodyData: bodyData,
                    sessionID: sessionID,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    eventLoop: eventLoop
                )
            }
        )
    }

    func respondToRefreshForwardAttempt(
        _ result: RefreshForwardAttemptResult,
        on channel: Channel,
        prefersEventStream: Bool,
        keepAlive: Bool,
        sessionID: String,
        requestLog: RequestLogContext
    ) {
        switch result {
        case .success(let responseData):
            if prefersEventStream {
                sendSingleSSE(
                    on: channel,
                    data: responseData,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            } else {
                var out = channel.allocator.buffer(capacity: responseData.count)
                out.writeBytes(responseData)
                sendJSON(
                    on: channel,
                    buffer: out,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            }
        case .timeout(let responseIDs, let isBatch):
            sendMCPError(
                on: channel,
                ids: responseIDs,
                code: -32000,
                message: "upstream timeout",
                forceBatchArray: isBatch,
                prefersEventStream: prefersEventStream,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        case .upstreamUnavailable(let responseIDs, let isBatch):
            if responseIDs.isEmpty {
                sendPlain(
                    on: channel,
                    status: .serviceUnavailable,
                    body: "upstream unavailable",
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            } else {
                sendMCPError(
                    on: channel,
                    ids: responseIDs,
                    code: -32001,
                    message: "upstream unavailable",
                    forceBatchArray: isBatch,
                    prefersEventStream: prefersEventStream,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            }
        case .overloaded(let responseIDs, let isBatch):
            if responseIDs.isEmpty {
                sendPlain(
                    on: channel,
                    status: .tooManyRequests,
                    body: "refresh queue overloaded",
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            } else {
                sendMCPError(
                    on: channel,
                    ids: responseIDs,
                    code: -32003,
                    message: "refresh queue overloaded",
                    forceBatchArray: isBatch,
                    prefersEventStream: prefersEventStream,
                    keepAlive: keepAlive,
                    sessionID: sessionID,
                    requestLog: requestLog
                )
            }
        case .invalidRequest:
            sendMCPError(
                on: channel,
                id: nil,
                code: -32700,
                message: "invalid json",
                prefersEventStream: prefersEventStream,
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        case .invalidUpstreamResponse:
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid upstream response",
                keepAlive: keepAlive,
                sessionID: sessionID,
                requestLog: requestLog
            )
        }
    }
}
