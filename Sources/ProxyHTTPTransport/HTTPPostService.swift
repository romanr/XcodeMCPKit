import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import ProxyCore
import ProxyRuntime

package enum HTTPPostResolution {
    case responseData(
        data: Data,
        sessionID: String,
        prefersEventStream: Bool
    )
    case mcpError(
        id: RPCID?,
        ids: [RPCID],
        code: Int,
        message: String,
        forceBatchArray: Bool,
        sessionID: String,
        prefersEventStream: Bool
    )
    case plain(
        status: HTTPResponseStatus,
        body: String,
        sessionID: String?
    )
    case empty(
        status: HTTPResponseStatus,
        sessionID: String
    )
}

package struct HTTPPostOperation {
    package let future: EventLoopFuture<HTTPPostResolution>
    package let cancellationHandle: HTTPPostCancellationHandle?
}

package enum HTTPPostCancellationSource: String, Sendable {
    case channelInactive
    case responseWriteFailure
}

package final class HTTPPostCancellationHandle: @unchecked Sendable {
    private struct State: Sendable {
        var upstreamIndex: Int?
        var routerPendingToken: UUID?
        var isTerminal = false
    }

    package let leaseID: RequestLeaseID
    package let sessionID: String
    package let requestIDKeys: [String]
    private let state = NIOLockedValueBox(State())

    package init(
        leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String]
    ) {
        self.leaseID = leaseID
        self.sessionID = sessionID
        self.requestIDKeys = requestIDKeys
    }

    package func activate(upstreamIndex: Int) {
        state.withLockedValue { state in
            guard !state.isTerminal else { return }
            state.upstreamIndex = upstreamIndex
        }
    }

    package func bindRouterPendingToken(_ token: UUID) {
        state.withLockedValue { state in
            guard !state.isTerminal else { return }
            state.routerPendingToken = token
        }
    }

    package func markCompleted() {
        state.withLockedValue { state in
            state.isTerminal = true
        }
    }

    package func cancel(using runtime: any RuntimeCoordinating) {
        let snapshot = state.withLockedValue { state -> (Int?, UUID?)? in
            guard !state.isTerminal else { return nil }
            state.isTerminal = true
            return (state.upstreamIndex, state.routerPendingToken)
        }
        guard let snapshot else { return }
        if let routerPendingToken = snapshot.1, runtime.hasSession(id: sessionID) {
            _ = runtime.session(id: sessionID).router.cancelPending(token: routerPendingToken)
        }
        runtime.abandonRequestLease(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDKeys,
            upstreamIndex: snapshot.0
        )
    }
}

package final class HTTPPostService: Sendable {
    private struct FilteredToolCallRequest: Sendable {
        let bodyData: Data?
        let localResponseData: Data?
        let forwardedResponseIDs: [RPCID]
        let forceBatchArray: Bool
    }

    private let sessionManager: any RuntimeCoordinating
    private let disabledToolNames: Set<String>
    private let localResponder: LocalMCPResponder
    private let forwardingService: MCPForwardingService
    private let requestTimeoutSeconds: TimeInterval
    private let logger: Logger

    package init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        logger: Logger = ProxyLogging.make("http")
    ) {
        self.requestTimeoutSeconds = config.requestTimeout
        self.sessionManager = sessionManager
        self.disabledToolNames = config.disabledToolNames
        self.localResponder = LocalMCPResponder(
            sessionManager: sessionManager,
            disabledToolNames: config.disabledToolNames,
            logger: ProxyLogging.make("http.local")
        )
        self.forwardingService = MCPForwardingService(
            config: config,
            sessionManager: sessionManager
        )
        self.logger = logger
    }

    package func handle(
        bodyData: Data,
        headerSessionID: String?,
        headerSessionExists: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop
    ) -> HTTPPostOperation {
        let requestMetadata = MCPErrorResponder.requestMetadata(from: bodyData)
        let requestIDs = requestMetadata.ids
        let requestIsBatch = requestMetadata.isBatch
        let parsedRequestJSON = try? JSONSerialization.jsonObject(with: bodyData, options: [])

        if let object = parsedRequestJSON as? [String: Any],
            let localHandling = localResponder.handle(
                object: object,
                headerSessionID: headerSessionID,
                headerSessionExists: headerSessionExists,
                eventLoop: eventLoop
            )
        {
            return HTTPPostOperation(
                future: resolveLocalHandling(
                    localHandling,
                    prefersEventStream: prefersEventStream,
                    eventLoop: eventLoop
                ),
                cancellationHandle: nil
            )
        }

        if let headerSessionID, !headerSessionExists {
            _ = sessionManager.session(id: headerSessionID)
        }

        let sessionID = headerSessionID ?? UUID().uuidString

        if sessionManager.isInitialized() == false {
            if requestIDs.isEmpty {
                return HTTPPostOperation(
                    future: eventLoop.makeSucceededFuture(
                        .plain(
                            status: .unprocessableEntity,
                            body: "expected initialize request",
                            sessionID: sessionID
                        )
                    ),
                    cancellationHandle: nil
                )
            }
            return HTTPPostOperation(
                future: eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: requestIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                ),
                cancellationHandle: nil
            )
        }

        guard let parsedRequestJSON else {
            return HTTPPostOperation(
                future: eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32700,
                        message: "invalid json",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                ),
                cancellationHandle: nil
            )
        }

        if headerSessionID == nil,
            let initializeResolution = Self.makeMissingInitializeResolution(
                parsedRequestJSON: parsedRequestJSON,
                requestIDs: requestIDs,
                requestIsBatch: requestIsBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        {
            return HTTPPostOperation(
                future: eventLoop.makeSucceededFuture(initializeResolution),
                cancellationHandle: nil
            )
        }

        let filteredRequest: FilteredToolCallRequest
        do {
            filteredRequest = try filterDisabledToolCalls(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                forceBatchArray: requestIsBatch
            )
        } catch {
            return HTTPPostOperation(
                future: eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32700,
                        message: "invalid json",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                ),
                cancellationHandle: nil
            )
        }

        guard let forwardedBodyData = filteredRequest.bodyData else {
            return HTTPPostOperation(
                future: eventLoop.makeSucceededFuture(
                    Self.makeLocalResponseResolution(
                        responseData: filteredRequest.localResponseData,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream,
                        emptyStatus: .accepted
                    )
                ),
                cancellationHandle: nil
            )
        }

        let forwardedRequestJSON: Any
        do {
            forwardedRequestJSON = try JSONSerialization.jsonObject(
                with: forwardedBodyData,
                options: []
            )
        } catch {
            return HTTPPostOperation(
                future: eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32700,
                        message: "invalid json",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                ),
                cancellationHandle: nil
            )
        }

        let forwardedRequestIDs = filteredRequest.forwardedResponseIDs
        let localResponseData = filteredRequest.localResponseData
        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: forwardedRequestJSON,
            requestIsBatch: requestIsBatch,
            requestIDs: forwardedRequestIDs
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = HTTPPostCancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: forwardedRequestIDs.map(\.key)
        )
        let session = sessionManager.session(id: sessionID)
        let future = sessionManager.enqueueOnUpstreamSlot(
            leaseID: leaseID,
            descriptor: descriptor,
            on: eventLoop,
            preferredUpstreamIndex: nil
        ) { upstreamIndex in
            cancellationHandle.activate(upstreamIndex: upstreamIndex)
            self.sessionManager.activateRequestLease(
                leaseID,
                requestIDKey: nil,
                upstreamIndex: upstreamIndex,
                timeout: nil
            )
            return self.makeTopLevelRequestFuture(
                filteredRequest: filteredRequest,
                sessionID: sessionID,
                headerSessionID: headerSessionID,
                requestIsBatch: requestIsBatch,
                prefersEventStream: prefersEventStream,
                eventLoop: eventLoop,
                session: session,
                leaseID: leaseID,
                upstreamIndex: upstreamIndex,
                cancellationHandle: cancellationHandle
            )
        }.flatMapError { error in
            if error is CancellationError {
                return eventLoop.makeFailedFuture(error)
            }
            cancellationHandle.markCompleted()
            self.sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamOverloaded
            )
            if localResponseData != nil {
                return eventLoop.makeSucceededFuture(
                    Self.makePartialBatchErrorResolution(
                        localResponseData: localResponseData,
                        responseIDs: forwardedRequestIDs,
                        code: -32001,
                        message: "upstream unavailable",
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream,
                        forceBatchArray: filteredRequest.forceBatchArray,
                        fallbackStatus: .serviceUnavailable,
                        fallbackBody: "upstream unavailable"
                    )
                )
            }
            if forwardedRequestIDs.isEmpty {
                return eventLoop.makeSucceededFuture(
                    .plain(
                        status: .serviceUnavailable,
                        body: "upstream unavailable",
                        sessionID: sessionID
                    )
                )
            }
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: nil,
                    ids: forwardedRequestIDs,
                    code: -32001,
                    message: "upstream unavailable",
                    forceBatchArray: requestIsBatch,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
        return HTTPPostOperation(
            future: future,
            cancellationHandle: cancellationHandle
        )
    }

    private func makeTopLevelRequestFuture(
        filteredRequest: FilteredToolCallRequest,
        sessionID: String,
        headerSessionID: String?,
        requestIsBatch: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        session: SessionContext,
        leaseID: RequestLeaseID,
        upstreamIndex: Int,
        cancellationHandle: HTTPPostCancellationHandle?
    ) -> EventLoopFuture<HTTPPostResolution> {
        guard let forwardedBodyData = filteredRequest.bodyData
        else {
            return makeImmediateLeaseResolution(
                Self.makeLocalResponseResolution(
                    responseData: filteredRequest.localResponseData,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream,
                    emptyStatus: .accepted
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        let forwardedRequestJSON: Any
        do {
            forwardedRequestJSON = try JSONSerialization.jsonObject(with: forwardedBodyData, options: [])
        } catch {
            return makeImmediateLeaseResolution(
                .mcpError(
                    id: nil,
                    ids: [],
                    code: -32700,
                    message: "invalid json",
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        let localResponseData = filteredRequest.localResponseData

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: forwardedBodyData,
                parsedRequestJSON: forwardedRequestJSON,
                sessionID: sessionID,
                upstreamIndexOverride: upstreamIndex
            ) else {
                if localResponseData != nil {
                    return makeImmediateLeaseResolution(
                        Self.makePartialBatchErrorResolution(
                            localResponseData: localResponseData,
                            responseIDs: filteredRequest.forwardedResponseIDs,
                            code: -32001,
                            message: "upstream unavailable",
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream,
                            forceBatchArray: filteredRequest.forceBatchArray,
                            fallbackStatus: .serviceUnavailable,
                            fallbackBody: "upstream unavailable"
                        ),
                        leaseID: leaseID,
                        eventLoop: eventLoop,
                        cancellationHandle: cancellationHandle
                    )
                }
                if filteredRequest.forwardedResponseIDs.isEmpty {
                    return makeImmediateLeaseResolution(
                        .plain(
                            status: .serviceUnavailable,
                            body: "upstream unavailable",
                            sessionID: sessionID
                        ),
                        leaseID: leaseID,
                        eventLoop: eventLoop,
                        cancellationHandle: cancellationHandle
                    )
                }
                return makeImmediateLeaseResolution(
                    .mcpError(
                        id: nil,
                        ids: filteredRequest.forwardedResponseIDs,
                        code: -32001,
                        message: "upstream unavailable",
                        forceBatchArray: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    ),
                    leaseID: leaseID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle
                )
            }
            prepared = candidate
        } catch {
            return makeImmediateLeaseResolution(
                .mcpError(
                    id: nil,
                    ids: [],
                    code: -32700,
                    message: "invalid json",
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                ),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        if prepared.transform.method == "tools/list" {
            let hasCache = sessionManager.cachedToolsListResult() != nil
            let params = (forwardedRequestJSON as? [String: Any])?["params"]
            let hasParams = params != nil && !(params is NSNull)
            logger.debug(
                "tools/list cache miss; forwarding upstream",
                metadata: [
                    "session": .string(sessionID),
                    "has_cache": .string(hasCache ? "true" : "false"),
                    "has_params": .string(hasParams ? "true" : "false"),
                    "upstream": .string("\(prepared.upstreamIndex)"),
                ]
            )
        }

        if headerSessionID == nil {
            if prepared.transform.isBatch || prepared.transform.method != "initialize"
                || !prepared.transform.expectsResponse
            {
                if prepared.transform.responseIDs.isEmpty {
                    return makeImmediateLeaseResolution(
                        .plain(
                            status: .unprocessableEntity,
                            body: "expected initialize request",
                            sessionID: sessionID
                        ),
                        leaseID: leaseID,
                        eventLoop: eventLoop,
                        cancellationHandle: cancellationHandle
                    )
                }
                return makeImmediateLeaseResolution(
                    .mcpError(
                        id: nil,
                        ids: prepared.transform.responseIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: prepared.transform.isBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    ),
                    leaseID: leaseID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle
                )
            }
        }

        if prepared.transform.expectsResponse {
            let started: MCPForwardingService.StartedRequest
            do {
                let requestTimeoutOverride = Self.topLevelRequestTimeoutOverride(
                    method: prepared.transform.method,
                    defaultSeconds: requestTimeoutSeconds
                )
                logger.debug(
                    "Starting top-level upstream request",
                    metadata: [
                        "lease_id": .string(leaseID.uuidString),
                        "session": .string(sessionID),
                        "label": .string(Self.requestLabel(from: forwardedRequestJSON)),
                        "upstream": .string("\(prepared.upstreamIndex)"),
                        "timeout_ms": .string(
                            requestTimeoutOverride.map { "\($0.nanoseconds / 1_000_000)" }
                                ?? "disabled"
                        ),
                    ]
                )
                started = try forwardingService.startRequest(
                    prepared,
                    session: session,
                    on: eventLoop,
                    requestTimeoutOverride: requestTimeoutOverride,
                    leaseID: leaseID,
                    onTimeout: {
                        self.sessionManager.handleRequestLeaseTimeout(
                            leaseID,
                            sessionID: sessionID,
                            requestIDKeys: prepared.transform.responseIDs.map(\.key),
                            upstreamIndex: prepared.upstreamIndex
                        )
                    }
                )
                cancellationHandle?.bindRouterPendingToken(started.routerPendingToken)
            } catch {
                return makeImmediateLeaseResolution(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32600,
                        message: "missing id",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    ),
                    leaseID: leaseID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle
                )
            }

            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            started.future.whenComplete { result in
                let resolution = self.forwardingService.resolveResponse(
                    result,
                    started: started,
                    sessionID: sessionID,
                    accountTimeout: false
                )
                switch resolution {
                case .success(let responseData):
                    cancellationHandle?.markCompleted()
                    self.sessionManager.completeRequestLease(leaseID)
                    self.logger.debug(
                        "Finished top-level upstream request",
                        metadata: [
                            "lease_id": .string(leaseID.uuidString),
                            "session": .string(sessionID),
                            "release_reason": .string("completed"),
                            "upstream": .string("\(prepared.upstreamIndex)"),
                            "request_ids": .string(started.transform.responseIDs.map(\.key).joined(separator: ",")),
                        ]
                    )
                    promise.succeed(
                        .responseData(
                            data: Self.mergeLocalBatchResponses(
                                into: responseData,
                                localResponseData: localResponseData
                            ),
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                case .invalidUpstreamResponse:
                    cancellationHandle?.markCompleted()
                    self.sessionManager.failRequestLease(
                        leaseID,
                        terminalState: .failed,
                        reason: .invalidUpstreamResponse
                    )
                    self.logger.debug(
                        "Finished top-level upstream request",
                        metadata: [
                            "lease_id": .string(leaseID.uuidString),
                            "session": .string(sessionID),
                            "release_reason": .string("invalidUpstreamResponse"),
                            "upstream": .string("\(prepared.upstreamIndex)"),
                            "request_ids": .string(started.transform.responseIDs.map(\.key).joined(separator: ",")),
                        ]
                    )
                    promise.succeed(
                        .plain(
                            status: .badGateway,
                            body: "invalid upstream response",
                            sessionID: sessionID
                        )
                    )
                case .timeout:
                    cancellationHandle?.markCompleted()
                    self.sessionManager.failRequestLease(
                        leaseID,
                        terminalState: .timedOut,
                        reason: .timedOut
                    )
                    self.logger.debug(
                        "Finished top-level upstream request",
                        metadata: [
                            "lease_id": .string(leaseID.uuidString),
                            "session": .string(sessionID),
                            "release_reason": .string("timedOut"),
                            "upstream": .string("\(prepared.upstreamIndex)"),
                            "request_ids": .string(started.transform.responseIDs.map(\.key).joined(separator: ",")),
                        ]
                    )
                    promise.succeed(
                        Self.makePartialBatchErrorResolution(
                            localResponseData: localResponseData,
                            responseIDs: started.transform.responseIDs,
                            code: -32000,
                            message: "upstream timeout",
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream,
                            forceBatchArray: started.transform.isBatch,
                            fallbackStatus: .ok,
                            fallbackBody: ""
                        )
                    )
                }
            }
            return promise.futureResult
        }

        if prepared.transform.method == "notifications/initialized" && sessionManager.isInitialized() {
            return makeImmediateLeaseResolution(
                .empty(status: .accepted, sessionID: sessionID),
                leaseID: leaseID,
                eventLoop: eventLoop,
                cancellationHandle: cancellationHandle
            )
        }

        sessionManager.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex,
            ensureRunning: false
        )
        return makeImmediateLeaseResolution(
            Self.makeLocalResponseResolution(
                responseData: localResponseData,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream,
                emptyStatus: .accepted
            ),
            leaseID: leaseID,
            eventLoop: eventLoop,
            cancellationHandle: cancellationHandle
        )
    }

    private func resolveLocalHandling(
        _ handling: LocalPostHandling,
        prefersEventStream: Bool,
        eventLoop: EventLoop
    ) -> EventLoopFuture<HTTPPostResolution> {
        switch handling {
        case .initialize(let future, let sessionID, let originalID):
            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            future.whenComplete { result in
                switch result {
                case .success(let buffer):
                    var buffer = buffer
                    guard let data = buffer.readData(length: buffer.readableBytes) else {
                        promise.succeed(
                            .plain(
                                status: .badGateway,
                                body: "invalid upstream response",
                                sessionID: sessionID
                            )
                        )
                        return
                    }
                    promise.succeed(
                        .responseData(
                            data: data,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                case .failure:
                    promise.succeed(
                        .mcpError(
                            id: originalID,
                            ids: [],
                            code: -32000,
                            message: "upstream timeout",
                            forceBatchArray: false,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            return promise.futureResult

        case .immediateResponse(let data, let sessionID):
            return eventLoop.makeSucceededFuture(
                .responseData(
                    data: data,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )

        case .mcpError(let id, let code, let message, let sessionID):
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: id,
                    ids: [],
                    code: code,
                    message: message,
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
    }

    private func filterDisabledToolCalls(
        bodyData: Data,
        parsedRequestJSON: Any,
        forceBatchArray: Bool
    ) throws -> FilteredToolCallRequest {
        guard disabledToolNames.isEmpty == false else {
            return FilteredToolCallRequest(
                bodyData: bodyData,
                localResponseData: nil,
                forwardedResponseIDs: Self.extractResponseIDs(from: parsedRequestJSON),
                forceBatchArray: forceBatchArray
            )
        }

        if let object = parsedRequestJSON as? [String: Any] {
            guard let toolName = blockedToolName(from: object) else {
                return FilteredToolCallRequest(
                    bodyData: bodyData,
                    localResponseData: nil,
                    forwardedResponseIDs: Self.extractResponseIDs(from: parsedRequestJSON),
                    forceBatchArray: forceBatchArray
                )
            }

            return FilteredToolCallRequest(
                bodyData: nil,
                localResponseData: Self.makeToolResponseData(
                    from: Self.makeBlockedToolResponseObjects(
                        requestObject: object,
                        toolName: toolName
                    ),
                    forceBatchArray: forceBatchArray
                ),
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        guard let array = parsedRequestJSON as? [Any] else {
            return FilteredToolCallRequest(
                bodyData: bodyData,
                localResponseData: nil,
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        var forwardedObjects: [Any] = []
        forwardedObjects.reserveCapacity(array.count)
        var localResponseObjects: [[String: Any]] = []
        localResponseObjects.reserveCapacity(array.count)

        for item in array {
            guard let object = item as? [String: Any],
                let toolName = blockedToolName(from: object)
            else {
                forwardedObjects.append(item)
                continue
            }
            localResponseObjects.append(
                contentsOf: Self.makeBlockedToolResponseObjects(
                    requestObject: object,
                    toolName: toolName
                )
            )
        }

        let localResponseData = Self.makeToolResponseData(
            from: localResponseObjects,
            forceBatchArray: forceBatchArray
        )
        let filteredAny = forwardedObjects.count != array.count

        guard forwardedObjects.isEmpty == false else {
            return FilteredToolCallRequest(
                bodyData: nil,
                localResponseData: localResponseData,
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        if localResponseData == nil, filteredAny == false {
            return FilteredToolCallRequest(
                bodyData: bodyData,
                localResponseData: nil,
                forwardedResponseIDs: Self.extractResponseIDs(from: parsedRequestJSON),
                forceBatchArray: forceBatchArray
            )
        }

        let filteredBodyData = try JSONSerialization.data(
            withJSONObject: forwardedObjects,
            options: []
        )
        return FilteredToolCallRequest(
            bodyData: filteredBodyData,
            localResponseData: localResponseData,
            forwardedResponseIDs: Self.extractResponseIDs(from: forwardedObjects),
            forceBatchArray: forceBatchArray
        )
    }

    private func blockedToolName(from requestObject: [String: Any]) -> String? {
        guard let method = requestObject["method"] as? String,
            method == "tools/call",
            let params = requestObject["params"] as? [String: Any],
            let toolName = params["name"] as? String,
            disabledToolNames.contains(toolName)
        else {
            return nil
        }
        return toolName
    }

    private static func requestLabel(from requestJSON: Any) -> String {
        if let object = requestJSON as? [String: Any] {
            let method = (object["method"] as? String) ?? "unknown"
            if method == "tools/call",
                let params = object["params"] as? [String: Any],
                let name = params["name"] as? String
            {
                return "\(method):\(name)"
            }
            return method
        }
        if let array = requestJSON as? [Any] {
            return "batch[\(array.count)]"
        }
        return "unknown"
    }

    private static func topLevelRequestDescriptor(
        sessionID: String,
        parsedRequestJSON: Any,
        requestIsBatch: Bool,
        requestIDs: [RPCID]
    ) -> SessionPipelineRequestDescriptor {
        SessionPipelineRequestDescriptor(
            sessionID: sessionID,
            label: requestLabel(from: parsedRequestJSON),
            isBatch: requestIsBatch,
            expectsResponse: requestIDs.isEmpty == false,
            isTopLevelClientRequest: true
        )
    }

    private func makeImmediateLeaseResolution(
        _ resolution: HTTPPostResolution,
        leaseID: RequestLeaseID,
        eventLoop: EventLoop,
        cancellationHandle: HTTPPostCancellationHandle?
    ) -> EventLoopFuture<HTTPPostResolution> {
        cancellationHandle?.markCompleted()
        sessionManager.completeRequestLease(leaseID)
        return eventLoop.makeSucceededFuture(resolution)
    }

    package func cancel(
        _ handle: HTTPPostCancellationHandle,
        source: HTTPPostCancellationSource = .channelInactive
    ) {
        logger.debug(
            "Cancelling top-level upstream request",
            metadata: [
                "lease_id": .string(handle.leaseID.uuidString),
                "session": .string(handle.sessionID),
                "disconnect_source": .string(source.rawValue),
                "request_ids": .string(handle.requestIDKeys.joined(separator: ",")),
            ]
        )
        handle.cancel(using: sessionManager)
    }

    private static func topLevelRequestTimeoutOverride(
        method: String?,
        defaultSeconds: TimeInterval
    ) -> TimeAmount? {
        MCPMethodDispatcher.timeoutForMethod(method, defaultSeconds: defaultSeconds)
    }

    private static func makeMissingInitializeResolution(
        parsedRequestJSON: Any,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        sessionID: String,
        prefersEventStream: Bool
    ) -> HTTPPostResolution? {
        guard requestRequiresInitialize(parsedRequestJSON) else {
            return nil
        }

        if requestIDs.isEmpty {
            return .plain(
                status: .unprocessableEntity,
                body: "expected initialize request",
                sessionID: sessionID
            )
        }

        return .mcpError(
            id: nil,
            ids: requestIDs,
            code: -32000,
            message: "expected initialize request",
            forceBatchArray: requestIsBatch,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    private static func requestRequiresInitialize(_ parsedRequestJSON: Any) -> Bool {
        if let object = parsedRequestJSON as? [String: Any] {
            let method = object["method"] as? String
            let expectsResponse = object["id"] != nil
            return method != "initialize" || !expectsResponse
        }
        if parsedRequestJSON is [Any] {
            return true
        }
        return false
    }

    private static func makeLocalResponseResolution(
        responseData: Data?,
        sessionID: String,
        prefersEventStream: Bool,
        emptyStatus: HTTPResponseStatus
    ) -> HTTPPostResolution {
        guard let responseData else {
            return .empty(status: emptyStatus, sessionID: sessionID)
        }
        return .responseData(
            data: responseData,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    private static func makePartialBatchErrorResolution(
        localResponseData: Data?,
        responseIDs: [RPCID],
        code: Int,
        message: String,
        sessionID: String,
        prefersEventStream: Bool,
        forceBatchArray: Bool,
        fallbackStatus: HTTPResponseStatus,
        fallbackBody: String
    ) -> HTTPPostResolution {
        guard let localResponseData else {
            if responseIDs.isEmpty {
                return .plain(
                    status: fallbackStatus,
                    body: fallbackBody,
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: code,
                message: message,
                forceBatchArray: forceBatchArray,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        }

        guard let localPayload = try? JSONSerialization.jsonObject(
            with: localResponseData,
            options: []
        ) else {
            if responseIDs.isEmpty {
                return .plain(
                    status: fallbackStatus,
                    body: fallbackBody,
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: code,
                message: message,
                forceBatchArray: forceBatchArray,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        }

        let localResponseObjects: [Any]
        if let array = localPayload as? [Any] {
            localResponseObjects = array
        } else if let object = localPayload as? [String: Any] {
            localResponseObjects = [object]
        } else {
            localResponseObjects = []
        }

        let mergedObjects =
            localResponseObjects
            + responseIDs.map { makeJSONRPCErrorResponseObject(id: $0, code: code, message: message) }
        guard JSONSerialization.isValidJSONObject(mergedObjects),
            let responseData = try? JSONSerialization.data(
                withJSONObject: mergedObjects,
                options: []
            )
        else {
            if responseIDs.isEmpty {
                return .plain(
                    status: fallbackStatus,
                    body: fallbackBody,
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: code,
                message: message,
                forceBatchArray: forceBatchArray,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        }

        return .responseData(
            data: responseData,
            sessionID: sessionID,
            prefersEventStream: prefersEventStream
        )
    }

    private static func mergeLocalBatchResponses(
        into responseData: Data,
        localResponseData: Data?
    ) -> Data {
        guard let localResponseData,
            let localPayload = try? JSONSerialization.jsonObject(
                with: localResponseData,
                options: []
            )
        else {
            return responseData
        }

        guard let any = try? JSONSerialization.jsonObject(with: responseData, options: []) else {
            return responseData
        }

        let mergedObjects: [Any]
        let localResponseObjects: [Any]
        if let array = localPayload as? [Any] {
            localResponseObjects = array
        } else if let object = localPayload as? [String: Any] {
            localResponseObjects = [object]
        } else {
            localResponseObjects = []
        }

        if let array = any as? [Any] {
            mergedObjects = array + localResponseObjects
        } else if let object = any as? [String: Any] {
            mergedObjects = [object] + localResponseObjects
        } else {
            return responseData
        }

        return (try? JSONSerialization.data(withJSONObject: mergedObjects, options: []))
            ?? responseData
    }

    private static func makeBlockedToolResponseObjects(
        requestObject: [String: Any],
        toolName: String
    ) -> [[String: Any]] {
        guard let requestID = requestObject["id"], let rpcID = RPCID(any: requestID) else {
            return []
        }
        return [makeToolResultErrorResponseObject(id: rpcID, toolName: toolName)]
    }

    private static func makeToolResultErrorResponseObject(
        id: RPCID,
        toolName: String
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": "tool '\(toolName)' is disabled by proxy config",
                    ]
                ],
                "isError": true,
            ],
        ]
    }

    private static func makeJSONRPCErrorResponseObject(
        id: RPCID,
        code: Int,
        message: String
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
    }

    private static func makeToolResponseData(
        from responseObjects: [[String: Any]],
        forceBatchArray: Bool
    ) -> Data? {
        guard responseObjects.isEmpty == false else {
            return nil
        }
        let payload: Any = (forceBatchArray || responseObjects.count > 1)
            ? responseObjects
            : responseObjects[0]
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private static func extractResponseIDs(from requestJSON: Any) -> [RPCID] {
        if let object = requestJSON as? [String: Any] {
            guard let rawID = object["id"], let rpcID = RPCID(any: rawID) else {
                return []
            }
            return [rpcID]
        }

        guard let array = requestJSON as? [Any] else {
            return []
        }
        return array.compactMap { item in
            guard let object = item as? [String: Any],
                let rawID = object["id"]
            else {
                return nil
            }
            return RPCID(any: rawID)
        }
    }
}
