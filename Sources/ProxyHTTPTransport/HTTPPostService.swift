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
    private let sessionManager: any RuntimeCoordinating
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
        self.localResponder = LocalMCPResponder(
            sessionManager: sessionManager,
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

        let descriptor = Self.topLevelRequestDescriptor(
            sessionID: sessionID,
            parsedRequestJSON: parsedRequestJSON,
            requestIsBatch: requestIsBatch,
            requestIDs: requestIDs
        )
        let leaseID = sessionManager.createRequestLease(descriptor: descriptor)
        let cancellationHandle = HTTPPostCancellationHandle(
            leaseID: leaseID,
            sessionID: sessionID,
            requestIDKeys: requestIDs.map(\.key)
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
                bodyData: bodyData,
                sessionID: sessionID,
                headerSessionID: headerSessionID,
                requestIDs: requestIDs,
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
            if requestIDs.isEmpty {
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
                    ids: requestIDs,
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
        bodyData: Data,
        sessionID: String,
        headerSessionID: String?,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop,
        session: SessionContext,
        leaseID: RequestLeaseID,
        upstreamIndex: Int,
        cancellationHandle: HTTPPostCancellationHandle?
    ) -> EventLoopFuture<HTTPPostResolution> {
        let parsedRequestJSON: Any
        do {
            parsedRequestJSON = try JSONSerialization.jsonObject(with: bodyData, options: [])
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

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                sessionID: sessionID,
                upstreamIndexOverride: upstreamIndex
            ) else {
                if requestIDs.isEmpty {
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
                    ids: requestIDs,
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
            let params = (parsedRequestJSON as? [String: Any])?["params"]
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
                        "label": .string(Self.requestLabel(from: parsedRequestJSON)),
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
                    on: eventLoop
                    ,
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
                            data: responseData,
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
                        .mcpError(
                            id: nil,
                            ids: started.transform.responseIDs,
                            code: -32000,
                            message: "upstream timeout",
                            forceBatchArray: started.transform.isBatch,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
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
            .empty(status: .accepted, sessionID: sessionID),
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
}
