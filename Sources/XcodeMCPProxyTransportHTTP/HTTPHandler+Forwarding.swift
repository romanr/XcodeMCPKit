import Foundation
import NIO
import NIOFoundationCompat
import NIOHTTP1
import XcodeMCPProxyCore
import XcodeMCPProxySession
import XcodeMCPProxyXcodeSupport

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

    func prepareForwardRequest(
        bodyData: Data,
        parsedRequestJSON: Any,
        sessionId: String,
        shouldPinUpstreamOverride: Bool? = nil
    ) throws -> PreparedForwardRequest? {
        let shouldPinUpstream =
            shouldPinUpstreamOverride ?? MCPMethodDispatcher.shouldPinUpstream(for: parsedRequestJSON)
        guard let upstreamIndex = sessionManager.chooseUpstreamIndex(
            sessionId: sessionId,
            shouldPin: shouldPinUpstream
        ) else {
            return nil
        }

        let transform = try RequestInspector.transform(
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
        return PreparedForwardRequest(
            transform: transform,
            upstreamIndex: upstreamIndex
        )
    }

    func startPreparedForwardRequest(
        _ prepared: PreparedForwardRequest,
        session: SessionContext,
        on eventLoop: EventLoop
    ) throws -> StartedForwardRequest {
        let requestTimeout = MCPMethodDispatcher.timeoutForMethod(
            prepared.transform.method,
            defaultSeconds: config.requestTimeout
        )
        let future: EventLoopFuture<ByteBuffer>
        if prepared.transform.isBatch {
            future = session.router.registerBatch(
                on: eventLoop,
                timeout: requestTimeout
            )
        } else if let idKey = prepared.transform.idKey {
            future = session.router.registerRequest(
                idKey: idKey,
                on: eventLoop,
                timeout: requestTimeout
            )
        } else {
            struct MissingRequestIDError: Error {}
            throw MissingRequestIDError()
        }

        sessionManager.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex
        )
        return StartedForwardRequest(
            transform: prepared.transform,
            upstreamIndex: prepared.upstreamIndex,
            future: future
        )
    }

    func resolveForwardResponse(
        _ result: Result<ByteBuffer, Error>,
        started: StartedForwardRequest,
        sessionId: String,
        accountSuccess: Bool = true,
        accountTimeout: Bool = true
    ) -> ForwardResponseResolution {
        switch result {
        case .success(let buffer):
            var buffer = buffer
            guard let data = buffer.readData(length: buffer.readableBytes) else {
                return .invalidUpstreamResponse
            }
            let responseData = rewriteUnsupportedResourcesListResponseIfNeeded(
                method: started.transform.method,
                originalId: started.transform.originalId,
                upstreamData: data
            )
            if started.transform.isCacheableToolsListRequest,
                let object = try? JSONSerialization.jsonObject(
                    with: responseData,
                    options: []
                ) as? [String: Any],
                let resultAny = object["result"],
                let result = JSONValue(any: resultAny)
            {
                sessionManager.setCachedToolsListResult(result)
            }
            if accountSuccess, shouldNotifyUpstreamSuccess(for: responseData) {
                for responseId in started.transform.responseIds {
                    sessionManager.onRequestSucceeded(
                        sessionId: sessionId,
                        requestIdKey: responseId.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .success(responseData)
        case .failure:
            if let firstResponseId = started.transform.responseIds.first {
                if accountTimeout {
                    sessionManager.onRequestTimeout(
                        sessionId: sessionId,
                        requestIdKey: firstResponseId.key,
                        upstreamIndex: started.upstreamIndex
                    )
                } else {
                    sessionManager.removeUpstreamIdMapping(
                        sessionId: sessionId,
                        requestIdKey: firstResponseId.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
                for responseId in started.transform.responseIds.dropFirst() {
                    sessionManager.removeUpstreamIdMapping(
                        sessionId: sessionId,
                        requestIdKey: responseId.key,
                        upstreamIndex: started.upstreamIndex
                    )
                }
            }
            return .timeout
        }
    }

    func callInternalTool(
        name: String,
        arguments: [String: Any],
        sessionId: String,
        eventLoop: EventLoop
    ) async -> [String: Any]? {
        let requestObject: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "__internal-\(UUID().uuidString)",
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestObject, options: [])
        else {
            return nil
        }

        let prepared: PreparedForwardRequest
        do {
            guard let candidate = try prepareForwardRequest(
                bodyData: bodyData,
                parsedRequestJSON: requestObject,
                sessionId: sessionId,
                shouldPinUpstreamOverride: false
            ) else {
                return nil
            }
            prepared = candidate
        } catch {
            return nil
        }

        let session = sessionManager.session(id: sessionId)
        let started: StartedForwardRequest
        do {
            started = try startPreparedForwardRequest(
                prepared,
                session: session,
                on: eventLoop
            )
        } catch {
            return nil
        }

        let resolution: ForwardResponseResolution
        do {
            let buffer = try await started.future.get()
            resolution = resolveForwardResponse(
                .success(buffer),
                started: started,
                sessionId: sessionId,
                accountSuccess: false,
                accountTimeout: false
            )
        } catch {
            resolution = resolveForwardResponse(
                .failure(error),
                started: started,
                sessionId: sessionId,
                accountSuccess: false,
                accountTimeout: false
            )
        }

        guard case .success(let responseData) = resolution,
            let object = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
            let result = object["result"] as? [String: Any]
        else {
            return nil
        }
        if let isError = result["isError"] as? Bool, isError {
            return nil
        }
        return result
    }

    func listXcodeWindows(
        sessionId: String,
        eventLoop: EventLoop
    ) async -> [XcodeWindowInfo]? {
        await windowQueryService.listWindows(
            sessionId: sessionId,
            eventLoop: eventLoop,
            toolCaller: { name, arguments, sessionId, eventLoop in
                await self.callInternalTool(
                    name: name,
                    arguments: arguments,
                    sessionId: sessionId,
                    eventLoop: eventLoop
                )
            }
        )
    }

    func forwardOnce(
        bodyData: Data,
        sessionId: String,
        requestIDs: [RPCId],
        requestIsBatch: Bool,
        eventLoop: EventLoop
    ) async -> RefreshForwardAttemptResult {
        let parsedRequestJSON: Any
        do {
            parsedRequestJSON = try JSONSerialization.jsonObject(with: bodyData, options: [])
        } catch {
            return .invalidRequest
        }

        let prepared: PreparedForwardRequest
        do {
            guard let candidate = try prepareForwardRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                sessionId: sessionId
            ) else {
                return .upstreamUnavailable(
                    responseIds: requestIDs,
                    isBatch: requestIsBatch
                )
            }
            prepared = candidate
        } catch {
            return .invalidRequest
        }

        let session = sessionManager.session(id: sessionId)
        let started: StartedForwardRequest
        do {
            started = try startPreparedForwardRequest(
                prepared,
                session: session,
                on: eventLoop
            )
        } catch {
            return .invalidRequest
        }

        let resolution: ForwardResponseResolution
        do {
            let buffer = try await started.future.get()
            resolution = resolveForwardResponse(
                .success(buffer),
                started: started,
                sessionId: sessionId
            )
        } catch {
            resolution = resolveForwardResponse(
                .failure(error),
                started: started,
                sessionId: sessionId
            )
        }

        switch resolution {
        case .success(let responseData):
            return .success(responseData)
        case .timeout:
            return .timeout(
                responseIds: started.transform.responseIds,
                isBatch: started.transform.isBatch
            )
        case .invalidUpstreamResponse:
            return .invalidUpstreamResponse
        }
    }

    func forwardRefreshCodeIssuesRequest(
        _ refreshRequest: RefreshCodeIssuesRequest,
        bodyData: Data,
        sessionId: String,
        requestIDs: [RPCId],
        requestIsBatch: Bool,
        eventLoop: EventLoop
    ) async -> RefreshForwardAttemptResult {
        await refreshWorkflow.run(
            refreshRequest: refreshRequest,
            bodyData: bodyData,
            sessionId: sessionId,
            requestIDs: requestIDs,
            requestIsBatch: requestIsBatch,
            eventLoop: eventLoop,
            windowsProvider: { sessionId, eventLoop in
                await self.listXcodeWindows(sessionId: sessionId, eventLoop: eventLoop)
            },
            forwarder: { bodyData, sessionId, requestIDs, requestIsBatch, eventLoop in
                await self.forwardOnce(
                    bodyData: bodyData,
                    sessionId: sessionId,
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
        sessionId: String,
        requestLog: RequestLogContext
    ) {
        switch result {
        case .success(let responseData):
            if prefersEventStream {
                sendSingleSSE(
                    on: channel,
                    data: responseData,
                    keepAlive: keepAlive,
                    sessionId: sessionId,
                    requestLog: requestLog
                )
            } else {
                var out = channel.allocator.buffer(capacity: responseData.count)
                out.writeBytes(responseData)
                sendJSON(
                    on: channel,
                    buffer: out,
                    keepAlive: keepAlive,
                    sessionId: sessionId,
                    requestLog: requestLog
                )
            }
        case .timeout(let responseIds, let isBatch):
            sendMCPError(
                on: channel,
                ids: responseIds,
                code: -32000,
                message: "upstream timeout",
                forceBatchArray: isBatch,
                prefersEventStream: prefersEventStream,
                keepAlive: keepAlive,
                sessionId: sessionId,
                requestLog: requestLog
            )
        case .upstreamUnavailable(let responseIds, let isBatch):
            if responseIds.isEmpty {
                sendPlain(
                    on: channel,
                    status: .serviceUnavailable,
                    body: "upstream unavailable",
                    keepAlive: keepAlive,
                    sessionId: sessionId,
                    requestLog: requestLog
                )
            } else {
                sendMCPError(
                    on: channel,
                    ids: responseIds,
                    code: -32001,
                    message: "upstream unavailable",
                    forceBatchArray: isBatch,
                    prefersEventStream: prefersEventStream,
                    keepAlive: keepAlive,
                    sessionId: sessionId,
                    requestLog: requestLog
                )
            }
        case .overloaded(let responseIds, let isBatch):
            if responseIds.isEmpty {
                sendPlain(
                    on: channel,
                    status: .tooManyRequests,
                    body: "refresh queue overloaded",
                    keepAlive: keepAlive,
                    sessionId: sessionId,
                    requestLog: requestLog
                )
            } else {
                sendMCPError(
                    on: channel,
                    ids: responseIds,
                    code: -32003,
                    message: "refresh queue overloaded",
                    forceBatchArray: isBatch,
                    prefersEventStream: prefersEventStream,
                    keepAlive: keepAlive,
                    sessionId: sessionId,
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
                sessionId: sessionId,
                requestLog: requestLog
            )
        case .invalidUpstreamResponse:
            sendPlain(
                on: channel,
                status: .badGateway,
                body: "invalid upstream response",
                keepAlive: keepAlive,
                sessionId: sessionId,
                requestLog: requestLog
            )
        }
    }
}
