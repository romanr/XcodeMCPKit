import Foundation
import Logging
import NIO
import NIOFoundationCompat
import NIOHTTP1
import XcodeMCPProxyCore
import XcodeMCPProxySession
import XcodeMCPProxyUpstream
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
        guard let result = await callInternalTool(
            name: "XcodeListWindows",
            arguments: [:],
            sessionId: sessionId,
            eventLoop: eventLoop
        ),
            let message = extractToolMessage(from: result)
        else {
            return nil
        }
        return parseXcodeListWindowsMessage(message)
    }

    func extractToolMessage(from result: [String: Any]) -> String? {
        if let structuredContent = result["structuredContent"] as? [String: Any],
            let message = structuredContent["message"] as? String,
            message.isEmpty == false
        {
            return message
        }

        guard let content = result["content"] as? [[String: Any]] else {
            return nil
        }
        for item in content {
            guard let text = item["text"] as? String, text.isEmpty == false else {
                continue
            }
            if let textData = text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: textData, options: []) as? [String: Any],
                let message = object["message"] as? String
            {
                return message
            }
            return text
        }
        return nil
    }

    func parseXcodeListWindowsMessage(_ message: String) -> [XcodeWindowInfo] {
        message
            .split(separator: "\n")
            .compactMap { line -> XcodeWindowInfo? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("* tabIdentifier: ") else { return nil }
                let parts = trimmed.components(separatedBy: ", workspacePath: ")
                guard parts.count == 2 else { return nil }
                let tabIdentifier = parts[0]
                    .replacingOccurrences(of: "* tabIdentifier: ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let workspacePath = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard tabIdentifier.isEmpty == false, workspacePath.isEmpty == false else {
                    return nil
                }
                return XcodeWindowInfo(
                    tabIdentifier: tabIdentifier,
                    workspacePath: workspacePath
                )
            }
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
        do {
            return try await refreshCodeIssuesCoordinator.withPermit(
                key: refreshRequest.queueKey
            ) { permit in
                let baseMetadata: Logger.Metadata = [
                    "session": .string(sessionId),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
                let queueMetadata: Logger.Metadata = [
                    "pending_for_key": .string("\(permit.pendingForKey)"),
                    "pending_total": .string("\(permit.pendingTotal)"),
                ]
                if permit.queuePosition > 0 {
                    logger.debug(
                        "Queued refresh code issues request",
                        metadata: baseMetadata.merging(
                            queueMetadata.merging(
                                ["queued_ahead": .string("\(permit.queuePosition)")],
                                uniquingKeysWith: { _, new in new }
                            ),
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                }
                logger.debug(
                    "Dequeued refresh code issues request",
                    metadata: baseMetadata.merging(
                        queueMetadata,
                        uniquingKeysWith: { _, new in new }
                    )
                )

                let warmupResult = await warmupDriver.warmUp(
                    tabIdentifier: refreshRequest.tabIdentifier,
                    filePath: refreshRequest.filePath,
                    sessionId: sessionId,
                    eventLoop: eventLoop,
                    windowsProvider: { sessionId, eventLoop in
                        await self.listXcodeWindows(
                            sessionId: sessionId,
                            eventLoop: eventLoop
                        )
                    }
                )
                let warmupMetadata = baseMetadata
                    .merging(
                        [
                            "workspace_path": .string(warmupResult.workspacePath ?? "none"),
                            "requested_file_path": .string(refreshRequest.filePath ?? "none"),
                            "resolved_file_path": .string(warmupResult.resolvedFilePath ?? "none"),
                        ],
                        uniquingKeysWith: { _, new in new }
                    )

                if let failureReason = warmupResult.failureReason,
                    failureReason != "disabled",
                    failureReason != "missing tabIdentifier",
                    failureReason != "missing filePath"
                {
                    logger.debug(
                        "Refresh code issues warm-up fell back to plain refresh",
                        metadata: warmupMetadata.merging(
                            [
                                "warmup_stage": .string("fallback"),
                                "failure_reason": .string(failureReason),
                            ],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                } else if warmupResult.context != nil {
                    logger.debug(
                        "Refresh code issues warm-up completed",
                        metadata: warmupMetadata.merging(
                            ["warmup_stage": .string("ready")],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                }
                var finalResult: RefreshForwardAttemptResult = .invalidRequest

                resultLoop: for attemptIndex in 0...Self.refreshRetryDelaysNanos.count {
                    let attempt = attemptIndex + 1
                    let attemptMetadata = warmupMetadata.merging(
                        ["attempt": .string("\(attempt)")],
                        uniquingKeysWith: { _, new in new }
                    )
                    if let context = warmupResult.context {
                        let touched = await warmupDriver.touchResolvedTarget(context)
                        logger.debug(
                            "Refresh code issues warm-up touch",
                            metadata: attemptMetadata.merging(
                                [
                                    "warmup_stage": .string("touch"),
                                    "touch_result": .string(touched ? "ready" : "failed"),
                                ],
                                uniquingKeysWith: { _, new in new }
                            )
                        )
                    }

                    let result = await forwardOnce(
                        bodyData: bodyData,
                        sessionId: sessionId,
                        requestIDs: requestIDs,
                        requestIsBatch: requestIsBatch,
                        eventLoop: eventLoop
                    )

                    switch result {
                    case .success(let responseData):
                        let retryable = isRetryableRefreshCodeIssuesFailure(responseData)
                        if retryable, attemptIndex < Self.refreshRetryDelaysNanos.count {
                            let delayNanos = Self.refreshRetryDelaysNanos[attemptIndex]
                            logger.debug(
                                "Retrying refresh code issues request after error 5",
                                metadata: attemptMetadata.merging(
                                    ["delay_ms": .string("\(delayNanos / 1_000_000)")],
                                    uniquingKeysWith: { _, new in new }
                                )
                            )
                            try? await Task.sleep(nanoseconds: delayNanos)
                            continue
                        }
                        if retryable {
                            logger.debug(
                                "Refresh code issues request still failing after retries",
                                metadata: attemptMetadata
                            )
                        }
                        finalResult = .success(responseData)
                        break resultLoop
                    case .timeout, .upstreamUnavailable, .overloaded, .invalidRequest,
                        .invalidUpstreamResponse:
                        finalResult = result
                        break resultLoop
                    }
                }

                let restoreResult = await warmupDriver.restore(warmupResult.context)
                if warmupResult.context?.snapshot != nil {
                    logger.debug(
                        "Refresh code issues restore finished",
                        metadata: warmupMetadata.merging(
                            ["restore_result": .string(restoreResult)],
                            uniquingKeysWith: { _, new in new }
                        )
                    )
                }
                return finalResult
            }
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueLimitExceeded {
            logger.warning(
                "Rejected refresh code issues request because queue is full",
                metadata: [
                    "session": .string(sessionId),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            return .overloaded(responseIds: requestIDs, isBatch: requestIsBatch)
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueWaitTimedOut {
            logger.warning(
                "Rejected refresh code issues request after queue wait timeout",
                metadata: [
                    "session": .string(sessionId),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            return .overloaded(responseIds: requestIDs, isBatch: requestIsBatch)
        } catch is CancellationError {
            logger.debug(
                "Cancelled queued refresh code issues request",
                metadata: [
                    "session": .string(sessionId),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            return .overloaded(responseIds: requestIDs, isBatch: requestIsBatch)
        } catch {
            return .invalidRequest
        }
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
