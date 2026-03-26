import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import ProxyCore
import ProxyFeatureXcode
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

private struct RefreshWorkflowExecution {
    let result: RefreshForwardAttemptResult
    let usedDirectForwarding: Bool
}

private struct RefreshRequestRoute: Sendable {
    let request: RefreshCodeIssuesRequest
    let bodyData: Data
    let requestIDs: [RPCID]
    let requestIsBatch: Bool
}

private struct RefreshRequestRouting: Sendable {
    let refreshRoutes: [RefreshRequestRoute]
    let remainingBodyData: Data?
    let remainingRequestIDs: [RPCID]
}

package enum HTTPPostCancellationSource: String, Sendable {
    case channelInactive
    case responseWriteFailure
}

package final class HTTPPostCancellationHandle: @unchecked Sendable {
    private struct State: Sendable {
        var requestIDKeys: [String]
        var upstreamIndex: Int?
        var routerPendingToken: UUID?
        var refreshTask: Task<Void, Never>?
        var childHandles: [HTTPPostCancellationHandle] = []
        var isTerminal = false
    }

    package let leaseID: RequestLeaseID
    package let sessionID: String
    private let state: NIOLockedValueBox<State>

    package init(
        leaseID: RequestLeaseID,
        sessionID: String,
        requestIDKeys: [String]
    ) {
        self.leaseID = leaseID
        self.sessionID = sessionID
        self.state = NIOLockedValueBox(
            State(requestIDKeys: requestIDKeys)
        )
    }

    package var requestIDKeys: [String] {
        state.withLockedValue { $0.requestIDKeys }
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

    package func bindRequestIDKeys(_ requestIDKeys: [String]) {
        state.withLockedValue { state in
            guard !state.isTerminal else { return }
            state.requestIDKeys = requestIDKeys
        }
    }

    package func markCompleted() {
        state.withLockedValue { state in
            state.isTerminal = true
            state.refreshTask = nil
            state.childHandles.removeAll()
        }
    }

    package func bindRefreshTask(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLockedValue { state -> Bool in
            guard !state.isTerminal else { return true }
            state.refreshTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    @discardableResult
    package func bindChildHandle(_ handle: HTTPPostCancellationHandle) -> Bool {
        state.withLockedValue { state in
            guard !state.isTerminal else { return false }
            state.childHandles.append(handle)
            return true
        }
    }

    package func cancel(using runtime: any RuntimeCoordinating) {
        let snapshot = state.withLockedValue {
            state -> (Int?, UUID?, Task<Void, Never>?, [HTTPPostCancellationHandle], [String])? in
            guard !state.isTerminal else { return nil }
            state.isTerminal = true
            let snapshot = (
                state.upstreamIndex,
                state.routerPendingToken,
                state.refreshTask,
                state.childHandles,
                state.requestIDKeys
            )
            state.refreshTask = nil
            state.childHandles = []
            return snapshot
        }
        guard let snapshot else { return }
        snapshot.2?.cancel()
        for childHandle in snapshot.3 {
            childHandle.cancel(using: runtime)
        }
        if let routerPendingToken = snapshot.1, runtime.hasSession(id: sessionID) {
            _ = runtime.session(id: sessionID).router.cancelPending(token: routerPendingToken)
        }
        runtime.abandonRequestLease(
            leaseID,
            sessionID: sessionID,
            requestIDKeys: snapshot.4,
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
    private let windowQueryService: XcodeWindowQueryService
    private let refreshWorkflow: RefreshCodeIssuesWorkflow
    private let requestTimeoutSeconds: TimeInterval
    private let logger: Logger

    package init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator,
        refreshCodeIssuesTargetResolver: RefreshCodeIssuesTargetResolver = RefreshCodeIssuesTargetResolver(),
        refreshCodeIssuesDebugState: RefreshCodeIssuesDebugState,
        logger: Logger = ProxyLogging.make("http")
    ) {
        self.requestTimeoutSeconds = config.requestTimeout
        self.sessionManager = sessionManager
        self.disabledToolNames = config.disabledToolNames
        self.localResponder = LocalMCPResponder(
            sessionManager: sessionManager,
            refreshCodeIssuesMode: config.refreshCodeIssuesMode,
            disabledToolNames: config.disabledToolNames,
            logger: ProxyLogging.make("http.local")
        )
        self.forwardingService = MCPForwardingService(
            config: config,
            sessionManager: sessionManager
        )
        self.windowQueryService = XcodeWindowQueryService()
        self.refreshWorkflow = RefreshCodeIssuesWorkflow(
            mode: config.refreshCodeIssuesMode,
            requestTimeout: config.requestTimeout,
            coordinator: refreshCodeIssuesCoordinator,
            targetResolver: refreshCodeIssuesTargetResolver,
            debugState: refreshCodeIssuesDebugState,
            logger: ProxyLogging.make("http.refresh")
        )
        self.logger = logger
    }

    package func handle(
        bodyData: Data,
        headerSessionID: String?,
        headerSessionExists: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        requestTimeoutOverride: TimeAmount? = nil,
        parentCancellationHandle: HTTPPostCancellationHandle? = nil
    ) -> HTTPPostOperation {
        let requestMetadata = MCPErrorResponder.requestMetadata(from: bodyData)
        let requestIDs = requestMetadata.ids
        let requestIsBatch = requestMetadata.isBatch
        let parsedRequestJSON = try? JSONSerialization.jsonObject(with: bodyData, options: [])

        if let localRequest = Self.localHandlingRequest(from: parsedRequestJSON),
            let localHandling = localResponder.handle(
                object: localRequest.object,
                headerSessionID: headerSessionID,
                headerSessionExists: headerSessionExists,
                eventLoop: eventLoop
            )
        {
            return HTTPPostOperation(
                future: resolveLocalHandling(
                    localHandling,
                    prefersEventStream: prefersEventStream,
                    eventLoop: eventLoop,
                    forceBatchArray: localRequest.forceBatchArray
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
            forwardedRequestJSON = try JSONSerialization.jsonObject(with: forwardedBodyData, options: [])
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
        if let parentCancellationHandle,
            parentCancellationHandle.bindChildHandle(cancellationHandle) == false
        {
            cancellationHandle.cancel(using: sessionManager)
            return HTTPPostOperation(
                future: eventLoop.makeSucceededFuture(
                    .empty(status: .accepted, sessionID: sessionID)
                ),
                cancellationHandle: nil
            )
        }
        let session = sessionManager.session(id: sessionID)
        let refreshRouting = refreshRequestRouting(from: forwardedRequestJSON)
        if refreshRouting != nil, forwardedRequestIDs.isEmpty == false {
            sessionManager.activateRequestLease(
                leaseID,
                requestIDKey: forwardedRequestIDs.first?.key,
                upstreamIndex: nil,
                timeout: requestTimeoutOverride
                    ?? Self.topLevelRequestTimeoutOverride(
                        method: nil,
                        defaultSeconds: requestTimeoutSeconds
                    )
            )
            return HTTPPostOperation(
                future: makeTopLevelRequestFuture(
                    filteredRequest: filteredRequest,
                    sessionID: sessionID,
                    headerSessionID: headerSessionID,
                    requestIsBatch: requestIsBatch,
                    prefersEventStream: prefersEventStream,
                    eventLoop: eventLoop,
                    session: session,
                    leaseID: leaseID,
                    upstreamIndex: -1,
                    cancellationHandle: cancellationHandle,
                    requestTimeoutOverride: requestTimeoutOverride
                ),
                cancellationHandle: cancellationHandle
            )
        }
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
                cancellationHandle: cancellationHandle,
                requestTimeoutOverride: requestTimeoutOverride
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
        cancellationHandle: HTTPPostCancellationHandle?,
        requestTimeoutOverride: TimeAmount?
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
        let refreshRouting = refreshRequestRouting(from: forwardedRequestJSON)

        if let refreshRouting, filteredRequest.forwardedResponseIDs.isEmpty == false {
            if headerSessionID == nil {
                return makeImmediateLeaseResolution(
                    .mcpError(
                    id: nil,
                    ids: filteredRequest.forwardedResponseIDs,
                    code: -32000,
                    message: "expected initialize request",
                    forceBatchArray: requestIsBatch,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                    ),
                    leaseID: leaseID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle
                )
            }

            if refreshRouting.refreshRoutes.count == 1,
                refreshRouting.remainingBodyData == nil,
                let route = refreshRouting.refreshRoutes.first
            {
                let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
                let refreshTask = Task { [self] in
                    let execution = await forwardRefreshCodeIssuesRequest(
                        route.request,
                        bodyData: route.bodyData,
                        sessionID: sessionID,
                        requestIDs: route.requestIDs,
                        requestIsBatch: route.requestIsBatch,
                        requestTimeoutOverride: requestTimeoutOverride,
                        eventLoop: eventLoop,
                        leaseID: leaseID,
                        cancellationHandle: cancellationHandle
                    )
                    let wasCancelled = Task.isCancelled
                    eventLoop.execute {
                        if wasCancelled {
                            cancellationHandle?.markCompleted()
                            promise.succeed(.empty(status: .accepted, sessionID: sessionID))
                            return
                        }
                        cancellationHandle?.markCompleted()
                        let resolution = self.makeResolution(
                            from: execution.result,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                        promise.succeed(
                            Self.makeLocalResponseResolution(
                                responseData: Self.mergeBatchResponsePayloads(
                                    [
                                        Self.responseDataForBatchResolution(
                                            resolution,
                                            fallbackRequestIDs: route.requestIDs,
                                            forceBatchArray: route.requestIsBatch
                                        ),
                                        localResponseData,
                                    ],
                                    forceBatchArray: requestIsBatch
                                ),
                                sessionID: sessionID,
                                prefersEventStream: prefersEventStream,
                                emptyStatus: .accepted
                            )
                        )
                        if execution.usedDirectForwarding == false {
                            self.sessionManager.completeRequestLease(leaseID)
                        }
                    }
                }
                cancellationHandle?.bindRefreshTask(refreshTask)
                return promise.futureResult
            }

            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            let refreshTask = Task { [self] in
                var payloads: [Data?] = []
                let splitDeadline = Self.timeoutDeadline(
                    for: requestTimeoutOverride
                        ?? Self.topLevelRequestTimeoutOverride(
                            method: nil,
                            defaultSeconds: requestTimeoutSeconds
                        )
                )

                for route in refreshRouting.refreshRoutes {
                    guard !Task.isCancelled else { break }
                    let remainingTimeout = Self.remainingRequestTimeout(
                        until: splitDeadline
                    )
                    if splitDeadline != nil, remainingTimeout == nil {
                        payloads.append(
                            Self.makeRequestTimeoutResponseData(
                                requestIDs: route.requestIDs,
                                forceBatchArray: route.requestIsBatch
                            )
                        )
                        continue
                    }
                    let operation = self.handle(
                        bodyData: route.bodyData,
                        headerSessionID: sessionID,
                        headerSessionExists: true,
                        prefersEventStream: prefersEventStream,
                        eventLoop: eventLoop,
                        requestTimeoutOverride: remainingTimeout,
                        parentCancellationHandle: cancellationHandle
                    )
                    let resolution = try? await operation.future.get()
                    payloads.append(
                        Self.responseDataForBatchResolution(
                            resolution,
                            fallbackRequestIDs: route.requestIDs,
                            forceBatchArray: route.requestIsBatch
                        )
                    )
                }

                if !Task.isCancelled,
                    let remainingBodyData = refreshRouting.remainingBodyData
                {
                    let remainingTimeout = Self.remainingRequestTimeout(
                        until: splitDeadline
                    )
                    if splitDeadline != nil, remainingTimeout == nil {
                        payloads.append(
                            Self.makeRequestTimeoutResponseData(
                                requestIDs: refreshRouting.remainingRequestIDs,
                                forceBatchArray: true
                            )
                        )
                    } else {
                        let operation = self.handle(
                            bodyData: remainingBodyData,
                            headerSessionID: sessionID,
                            headerSessionExists: true,
                            prefersEventStream: prefersEventStream,
                            eventLoop: eventLoop,
                            requestTimeoutOverride: remainingTimeout,
                            parentCancellationHandle: cancellationHandle
                        )
                        let resolution = try? await operation.future.get()
                        payloads.append(
                            Self.responseDataForBatchResolution(
                                resolution,
                                fallbackRequestIDs: refreshRouting.remainingRequestIDs,
                                forceBatchArray: true
                            )
                        )
                    }
                }

                let wasCancelled = Task.isCancelled
                let mergedPayloadInputs = payloads + [localResponseData]
                eventLoop.execute {
                    if wasCancelled {
                        cancellationHandle?.markCompleted()
                        promise.succeed(.empty(status: .accepted, sessionID: sessionID))
                        return
                    }
                    cancellationHandle?.markCompleted()
                    let mergedData = Self.mergeBatchResponsePayloads(
                        mergedPayloadInputs,
                        forceBatchArray: requestIsBatch
                    )
                    promise.succeed(
                        Self.makeLocalResponseResolution(
                            responseData: mergedData,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream,
                            emptyStatus: .accepted
                        )
                    )
                    self.sessionManager.completeRequestLease(leaseID)
                }
            }
            cancellationHandle?.bindRefreshTask(refreshTask)
            return promise.futureResult
        }

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
                let methodRequestTimeoutOverride = Self.topLevelRequestTimeoutOverride(
                    method: prepared.transform.method,
                    defaultSeconds: requestTimeoutSeconds
                )
                let effectiveRequestTimeoutOverride = Self.minimumRequestTimeout(
                    methodRequestTimeoutOverride,
                    requestTimeoutOverride
                )
                logger.debug(
                    "Starting top-level upstream request",
                    metadata: [
                        "lease_id": .string(leaseID.uuidString),
                        "session": .string(sessionID),
                        "label": .string(Self.requestLabel(from: forwardedRequestJSON)),
                        "upstream": .string("\(prepared.upstreamIndex)"),
                        "timeout_ms": .string(
                            effectiveRequestTimeoutOverride.map {
                                "\($0.nanoseconds / 1_000_000)"
                            }
                                ?? "disabled"
                        ),
                    ]
                )
                started = try forwardingService.startRequest(
                    prepared,
                    session: session,
                    on: eventLoop
                    ,
                    requestTimeoutOverride: effectiveRequestTimeoutOverride,
                    leaseID: leaseID,
                    cancellationHandle: cancellationHandle,
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
        eventLoop: EventLoop,
        forceBatchArray: Bool
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
                    let responseData = forceBatchArray
                        ? Self.forceBatchArrayResponseDataIfNeeded(data)
                        : data
                    promise.succeed(
                        .responseData(
                            data: responseData,
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
                            forceBatchArray: forceBatchArray,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            return promise.futureResult

        case .immediateResponse(let data, let sessionID):
            let responseData = forceBatchArray
                ? Self.forceBatchArrayResponseDataIfNeeded(data)
                : data
            return eventLoop.makeSucceededFuture(
                .responseData(
                    data: responseData,
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
                    forceBatchArray: forceBatchArray,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }
    }

    private static func localHandlingRequest(from parsedRequestJSON: Any?) -> (
        object: [String: Any], forceBatchArray: Bool
    )? {
        if let object = parsedRequestJSON as? [String: Any] {
            return (object, false)
        }
        guard let array = parsedRequestJSON as? [Any],
            array.count == 1,
            let object = array.first as? [String: Any]
        else {
            return nil
        }
        return (object, true)
    }

    private static func forceBatchArrayResponseDataIfNeeded(_ data: Data) -> Data {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return data
        }
        guard payload is [Any] == false,
            JSONSerialization.isValidJSONObject([payload])
        else {
            return data
        }
        return (try? JSONSerialization.data(withJSONObject: [payload], options: [])) ?? data
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

        guard forwardedObjects.isEmpty == false else {
            return FilteredToolCallRequest(
                bodyData: nil,
                localResponseData: localResponseData,
                forwardedResponseIDs: [],
                forceBatchArray: forceBatchArray
            )
        }

        if localResponseData == nil {
            let filteredPayload: Any = (forceBatchArray || forwardedObjects.count > 1)
                ? forwardedObjects
                : forwardedObjects[0]
            let filteredBodyData = try JSONSerialization.data(
                withJSONObject: filteredPayload,
                options: []
            )
            return FilteredToolCallRequest(
                bodyData: filteredBodyData,
                localResponseData: nil,
                forwardedResponseIDs: Self.extractResponseIDs(from: filteredPayload),
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

    private func refreshCodeIssuesRequest(from requestJSON: Any) -> RefreshCodeIssuesRequest? {
        if let object = requestJSON as? [String: Any] {
            return refreshCodeIssuesRequest(from: object)
        }

        guard let requests = requestJSON as? [Any],
            requests.count == 1,
            let object = requests.first as? [String: Any]
        else {
            return nil
        }
        return refreshCodeIssuesRequest(from: object)
    }

    private func refreshCodeIssuesRequest(from object: [String: Any]) -> RefreshCodeIssuesRequest? {
        guard
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

    private func refreshRequestRouting(from requestJSON: Any) -> RefreshRequestRouting? {
        if let object = requestJSON as? [String: Any],
            let refreshRequest = refreshCodeIssuesRequest(from: object),
            let bodyData = try? JSONSerialization.data(withJSONObject: object, options: [])
        {
            return RefreshRequestRouting(
                refreshRoutes: [
                    RefreshRequestRoute(
                        request: refreshRequest,
                        bodyData: bodyData,
                        requestIDs: Self.extractResponseIDs(from: object),
                        requestIsBatch: false
                    )
                ],
                remainingBodyData: nil,
                remainingRequestIDs: []
            )
        }

        guard let requests = requestJSON as? [Any] else {
            return nil
        }
        var refreshRoutes: [RefreshRequestRoute] = []
        var remainingObjects: [Any] = []
        for (index, item) in requests.enumerated() {
            guard let object = item as? [String: Any],
                let candidate = refreshCodeIssuesRequest(from: object)
            else {
                remainingObjects.append(item)
                continue
            }
            let payload: Any = requests.count == 1 ? requests : object
            guard let bodyData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                return nil
            }
            refreshRoutes.append(
                RefreshRequestRoute(
                    request: candidate,
                    bodyData: bodyData,
                    requestIDs: Self.extractResponseIDs(from: object),
                    requestIsBatch: requests.count == 1
                )
            )
            _ = index
        }
        guard !refreshRoutes.isEmpty else {
            return nil
        }

        let remainingPayload: Any? = {
            guard !remainingObjects.isEmpty else { return nil }
            return remainingObjects.count == 1 ? remainingObjects[0] : remainingObjects
        }()
        let remainingBodyData = remainingPayload.flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [])
        }
        return RefreshRequestRouting(
            refreshRoutes: refreshRoutes,
            remainingBodyData: remainingBodyData,
            remainingRequestIDs: Self.extractResponseIDs(from: remainingPayload as Any)
        )
    }

    private func callInternalTool(
        name: String,
        arguments: [String: Any],
        sessionID: String,
        eventLoop: EventLoop,
        cancellationHandle: HTTPPostCancellationHandle? = nil,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshInternalToolResult {
        await forwardingService.callInternalTool(
            name: name,
            arguments: arguments,
            sessionID: sessionID,
            eventLoop: eventLoop,
            cancellationHandle: cancellationHandle,
            upstreamIndexOverride: upstreamIndexOverride,
            requestTimeoutOverride: requestTimeoutOverride
        )
    }

    private func listXcodeWindows(
        sessionID: String,
        eventLoop: EventLoop,
        cancellationHandle: HTTPPostCancellationHandle? = nil,
        upstreamIndexOverride: Int? = nil,
        requestTimeoutOverride: TimeAmount? = nil
    ) async throws -> [XcodeWindowInfo]? {
        try await windowQueryService.listWindows(
            sessionID: sessionID,
            eventLoop: eventLoop,
            toolCaller: { name, arguments, sessionID, eventLoop in
                switch await self.callInternalTool(
                    name: name,
                    arguments: arguments,
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle,
                    upstreamIndexOverride: upstreamIndexOverride,
                    requestTimeoutOverride: requestTimeoutOverride
                ) {
                case .success(let result):
                    return result
                case .cancelled:
                    throw CancellationError()
                case .timeout, .unavailable:
                    return nil
                }
            }
        )
    }

    private func forwardOnce(
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        shouldRequeueLeaseOnRetryableFailure: @Sendable () -> Bool,
        eventLoop: EventLoop,
        leaseID: RequestLeaseID,
        cancellationHandle: HTTPPostCancellationHandle?,
        requestTimeoutOverride: TimeAmount? = nil
    ) async -> RefreshForwardAttemptResult {
        let parsedRequestJSON: Any
        do {
            parsedRequestJSON = try JSONSerialization.jsonObject(with: bodyData, options: [])
        } catch {
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .invalidUpstreamResponse
            )
            return .invalidRequest
        }

        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: parsedRequestJSON,
            requestIsBatch: requestIsBatch,
            requestIDs: requestIDs
        )
        let allowsLeaseRetry = Self.isRetryScopedRefreshLeaseRequest(parsedRequestJSON)

        do {
            let session = sessionManager.session(id: sessionID)
            let resolution = try await sessionManager.enqueueOnUpstreamSlot(
                leaseID: leaseID,
                descriptor: descriptor,
                on: eventLoop,
                preferredUpstreamIndex: nil
            ) { selectedUpstreamIndex in
                cancellationHandle?.activate(upstreamIndex: selectedUpstreamIndex)

                let parsedAttemptRequestJSON: Any
                do {
                    parsedAttemptRequestJSON = try JSONSerialization.jsonObject(
                        with: bodyData,
                        options: []
                    )
                } catch {
                    return eventLoop.makeSucceededFuture(
                        MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                    )
                }

                let prepared: MCPForwardingService.PreparedRequest
                do {
                    guard let candidate = try self.forwardingService.prepareRequest(
                        bodyData: bodyData,
                        parsedRequestJSON: parsedAttemptRequestJSON,
                        sessionID: sessionID,
                        upstreamIndexOverride: selectedUpstreamIndex
                    ) else {
                        return eventLoop.makeSucceededFuture(
                            MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                        )
                    }
                    prepared = candidate
                } catch {
                    return eventLoop.makeSucceededFuture(
                        MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                    )
                }

                let started: MCPForwardingService.StartedRequest
                do {
                    started = try self.forwardingService.startRequest(
                        prepared,
                        session: session,
                        on: eventLoop,
                        requestTimeoutOverride: requestTimeoutOverride,
                        leaseID: leaseID,
                        cancellationHandle: cancellationHandle,
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
                    return eventLoop.makeSucceededFuture(
                        MCPForwardingService.ResponseResolution.invalidUpstreamResponse
                    )
                }

                return started.future.map { buffer in
                    self.forwardingService.resolveResponse(
                        .success(buffer),
                        started: started,
                        sessionID: sessionID,
                        accountTimeout: false
                    )
                }.flatMapErrorThrowing { error in
                    self.forwardingService.resolveResponse(
                        .failure(error),
                        started: started,
                        sessionID: sessionID,
                        accountTimeout: false
                    )
                }
            }.get()

            switch resolution {
            case .success(let responseData):
                if allowsLeaseRetry,
                    RefreshCodeIssuesWorkflow.isRetryableRefreshCodeIssuesFailure(responseData),
                    shouldRequeueLeaseOnRetryableFailure()
                {
                    sessionManager.requeueRequestLease(leaseID)
                } else {
                    sessionManager.completeRequestLease(leaseID)
                }
                return .success(responseData)
            case .timeout:
                sessionManager.failRequestLease(
                    leaseID,
                    terminalState: .timedOut,
                    reason: .timedOut
                )
                return .timeout(
                    responseIDs: requestIDs,
                    isBatch: requestIsBatch
                )
            case .invalidUpstreamResponse:
                sessionManager.failRequestLease(
                    leaseID,
                    terminalState: .failed,
                    reason: .invalidUpstreamResponse
                )
                return .invalidUpstreamResponse
            }
        } catch is CancellationError {
            return .cancelled(
                responseIDs: requestIDs,
                isBatch: requestIsBatch
            )
        } catch {
            sessionManager.failRequestLease(
                leaseID,
                terminalState: .failed,
                reason: .upstreamUnavailable
            )
            return .upstreamUnavailable(
                responseIDs: requestIDs,
                isBatch: requestIsBatch
            )
        }
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

    private static func isRetryScopedRefreshLeaseRequest(_ requestJSON: Any) -> Bool {
        if let object = requestJSON as? [String: Any] {
            return isRefreshCodeIssuesRequestObject(object)
        }
        guard let array = requestJSON as? [Any],
            array.count == 1,
            let object = array.first as? [String: Any]
        else {
            return false
        }
        return isRefreshCodeIssuesRequestObject(object)
    }

    private static func isRefreshCodeIssuesRequestObject(_ object: [String: Any]) -> Bool {
        guard object["method"] as? String == "tools/call",
            let params = object["params"] as? [String: Any]
        else {
            return false
        }
        return params["name"] as? String == "XcodeRefreshCodeIssuesInFile"
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

    private func forwardRefreshCodeIssuesRequest(
        _ refreshRequest: RefreshCodeIssuesRequest,
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        requestTimeoutOverride: TimeAmount? = nil,
        eventLoop: EventLoop,
        leaseID: RequestLeaseID,
        cancellationHandle: HTTPPostCancellationHandle?
    ) async -> RefreshWorkflowExecution {
        let usedDirectForwarding = NIOLockedValueBox(false)
        let result = await refreshWorkflow.run(
            refreshRequest: refreshRequest,
            bodyData: bodyData,
            sessionID: sessionID,
            requestIDs: requestIDs,
            requestIsBatch: requestIsBatch,
            requestTimeoutOverride: requestTimeoutOverride,
            eventLoop: eventLoop,
            windowsProvider: { sessionID, eventLoop, upstreamIndexOverride, requestTimeoutOverride in
                try await self.listXcodeWindows(
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle,
                    upstreamIndexOverride: upstreamIndexOverride,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            },
            internalUpstreamChooser: { _ in
                self.sessionManager.chooseUpstreamIndex()
            },
            internalToolCaller: {
                name, arguments, sessionID, eventLoop, upstreamIndexOverride, requestTimeoutOverride in
                await self.callInternalTool(
                    name: name,
                    arguments: arguments,
                    sessionID: sessionID,
                    eventLoop: eventLoop,
                    cancellationHandle: cancellationHandle,
                    upstreamIndexOverride: upstreamIndexOverride,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            },
            forwarder: {
                bodyData, sessionID, requestIDs, requestIsBatch, shouldRequeueLeaseOnRetryableFailure, eventLoop, requestTimeoutOverride in
                usedDirectForwarding.withLockedValue { $0 = true }
                return await self.forwardOnce(
                    bodyData: bodyData,
                    sessionID: sessionID,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    shouldRequeueLeaseOnRetryableFailure: shouldRequeueLeaseOnRetryableFailure,
                    eventLoop: eventLoop,
                    leaseID: leaseID,
                    cancellationHandle: cancellationHandle,
                    requestTimeoutOverride: requestTimeoutOverride
                )
            }
        )
        return RefreshWorkflowExecution(
            result: result,
            usedDirectForwarding: usedDirectForwarding.withLockedValue { $0 }
        )
    }

    private func makeResolution(
        from result: RefreshForwardAttemptResult,
        sessionID: String,
        prefersEventStream: Bool
    ) -> HTTPPostResolution {
        switch result {
        case .success(let responseData):
            return .responseData(
                data: responseData,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .timeout(let responseIDs, let isBatch):
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: -32000,
                message: "upstream timeout",
                forceBatchArray: isBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .upstreamUnavailable(let responseIDs, let isBatch):
            if responseIDs.isEmpty {
                return .plain(
                    status: .serviceUnavailable,
                    body: "upstream unavailable",
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: -32001,
                message: "upstream unavailable",
                forceBatchArray: isBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .overloaded(let responseIDs, let isBatch):
            if responseIDs.isEmpty {
                return .plain(
                    status: .tooManyRequests,
                    body: "refresh queue overloaded",
                    sessionID: sessionID
                )
            }
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: -32003,
                message: "refresh queue overloaded",
                forceBatchArray: isBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .cancelled(let responseIDs, let isBatch):
            return .mcpError(
                id: nil,
                ids: responseIDs,
                code: -32800,
                message: "request cancelled",
                forceBatchArray: isBatch,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .invalidRequest:
            return .mcpError(
                id: nil,
                ids: [],
                code: -32700,
                message: "invalid json",
                forceBatchArray: false,
                sessionID: sessionID,
                prefersEventStream: prefersEventStream
            )
        case .invalidUpstreamResponse:
            return .plain(
                status: .badGateway,
                body: "invalid upstream response",
                sessionID: sessionID
            )
        }
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

    private static func minimumRequestTimeout(
        _ lhs: TimeAmount?,
        _ rhs: TimeAmount?
    ) -> TimeAmount? {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case let (.some(value), .none), let (.none, .some(value)):
            return value
        case let (.some(lhs), .some(rhs)):
            return lhs.nanoseconds <= rhs.nanoseconds ? lhs : rhs
        }
    }

    private static func timeoutDeadline(for timeout: TimeAmount?) -> Date? {
        guard let timeout else { return nil }
        let seconds = Double(timeout.nanoseconds) / 1_000_000_000
        return Date().addingTimeInterval(seconds)
    }

    private static func remainingRequestTimeout(until deadline: Date?) -> TimeAmount? {
        guard let deadline else { return nil }
        let remainingSeconds = deadline.timeIntervalSinceNow
        guard remainingSeconds > 0 else { return nil }
        let remainingNanoseconds = Int64((remainingSeconds * 1_000_000_000).rounded(.up))
        return .nanoseconds(remainingNanoseconds)
    }

    private static func makeRequestTimeoutResponseData(
        requestIDs: [RPCID],
        forceBatchArray: Bool
    ) -> Data? {
        makeJSONRPCErrorResponseData(
            ids: requestIDs,
            code: -32000,
            message: "upstream timeout",
            forceBatchArray: forceBatchArray
        )
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

    private static func mergeBatchResponsePayloads(
        _ payloads: [Data?],
        forceBatchArray: Bool
    ) -> Data? {
        let objects = payloads.compactMap { $0 }.flatMap { data -> [Any] in
            guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
                return []
            }
            if let array = payload as? [Any] {
                return array
            }
            if let object = payload as? [String: Any] {
                return [object]
            }
            return []
        }
        guard !objects.isEmpty else {
            return nil
        }
        let payload: Any = (forceBatchArray || objects.count > 1) ? objects : objects[0]
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private static func responseDataForBatchResolution(
        _ resolution: HTTPPostResolution?,
        fallbackRequestIDs: [RPCID],
        forceBatchArray: Bool
    ) -> Data? {
        guard let resolution else {
            return nil
        }
        switch resolution {
        case .responseData(let data, _, _):
            return data
        case .mcpError(_, let ids, let code, let message, let batch, _, _):
            return makeJSONRPCErrorResponseData(
                ids: ids.isEmpty ? fallbackRequestIDs : ids,
                code: code,
                message: message,
                forceBatchArray: batch || forceBatchArray
            )
        case .plain(_, let body, _):
            return makeJSONRPCErrorResponseData(
                ids: fallbackRequestIDs,
                code: -32000,
                message: body.isEmpty ? "request failed" : body,
                forceBatchArray: forceBatchArray
            )
        case .empty:
            return nil
        }
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

    private static func makeJSONRPCErrorResponseData(
        ids: [RPCID],
        code: Int,
        message: String,
        forceBatchArray: Bool
    ) -> Data? {
        let objects = ids.map { makeJSONRPCErrorResponseObject(id: $0, code: code, message: message) }
        guard !objects.isEmpty else {
            return nil
        }
        let payload: Any = (forceBatchArray || objects.count > 1) ? objects : objects[0]
        guard JSONSerialization.isValidJSONObject(payload) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
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
