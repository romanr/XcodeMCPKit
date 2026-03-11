import Foundation
import Logging
import NIO
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

package final class HTTPPostService: Sendable {
    private let sessionManager: any RuntimeCoordinating
    private let localResponder: LocalMCPResponder
    private let forwardingService: MCPForwardingService
    private let windowQueryService: XcodeWindowQueryService
    private let refreshWorkflow: RefreshCodeIssuesWorkflow
    private let logger: Logger

    package init(
        config: ProxyConfig,
        sessionManager: any RuntimeCoordinating,
        refreshCodeIssuesCoordinator: RefreshCodeIssuesCoordinator? = nil,
        warmupDriver: XcodeEditorWarmupDriver = XcodeEditorWarmupDriver(),
        logger: Logger = ProxyLogging.make("http")
    ) {
        self.sessionManager = sessionManager
        self.localResponder = LocalMCPResponder(
            sessionManager: sessionManager,
            logger: ProxyLogging.make("http.local")
        )
        self.forwardingService = MCPForwardingService(
            config: config,
            sessionManager: sessionManager
        )
        let refreshCoordinator =
            refreshCodeIssuesCoordinator
            ?? RefreshCodeIssuesCoordinator.makeDefault(
                requestTimeout: config.requestTimeout
            )
        self.windowQueryService = XcodeWindowQueryService()
        self.refreshWorkflow = RefreshCodeIssuesWorkflow(
            coordinator: refreshCoordinator,
            warmupDriver: warmupDriver,
            logger: ProxyLogging.make("http.refresh")
        )
        self.logger = logger
    }

    package func handle(
        bodyData: Data,
        headerSessionID: String?,
        headerSessionExists: Bool,
        prefersEventStream: Bool,
        eventLoop: EventLoop
    ) -> EventLoopFuture<HTTPPostResolution> {
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
            return resolveLocalHandling(
                localHandling,
                prefersEventStream: prefersEventStream,
                eventLoop: eventLoop
            )
        }

        if let headerSessionID, !headerSessionExists {
            _ = sessionManager.session(id: headerSessionID)
        }

        let sessionID = headerSessionID ?? UUID().uuidString

        if sessionManager.isInitialized() == false {
            if requestIDs.isEmpty {
                return eventLoop.makeSucceededFuture(
                    .plain(
                        status: .unprocessableEntity,
                        body: "expected initialize request",
                        sessionID: sessionID
                    )
                )
            }
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: nil,
                    ids: requestIDs,
                    code: -32000,
                    message: "expected initialize request",
                    forceBatchArray: requestIsBatch,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }

        guard let parsedRequestJSON else {
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: nil,
                    ids: [],
                    code: -32700,
                    message: "invalid json",
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
            )
        }

        let refreshRequest = requestIsBatch ? nil : refreshCodeIssuesRequest(from: parsedRequestJSON)
        if let refreshRequest, requestIDs.isEmpty == false {
            if headerSessionID == nil {
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: requestIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: requestIsBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            Task { [self] in
                let attemptResult = await forwardRefreshCodeIssuesRequest(
                    refreshRequest,
                    bodyData: bodyData,
                    sessionID: sessionID,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    eventLoop: eventLoop
                )
                eventLoop.execute {
                    promise.succeed(
                        self.makeResolution(
                            from: attemptResult,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                }
            }
            return promise.futureResult
        }

        let prepared: MCPForwardingService.PreparedRequest
        do {
            guard let candidate = try forwardingService.prepareRequest(
                bodyData: bodyData,
                parsedRequestJSON: parsedRequestJSON,
                sessionID: sessionID
            ) else {
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
            prepared = candidate
        } catch {
            return eventLoop.makeSucceededFuture(
                .mcpError(
                    id: nil,
                    ids: [],
                    code: -32700,
                    message: "invalid json",
                    forceBatchArray: false,
                    sessionID: sessionID,
                    prefersEventStream: prefersEventStream
                )
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
                    return eventLoop.makeSucceededFuture(
                        .plain(
                            status: .unprocessableEntity,
                            body: "expected initialize request",
                            sessionID: sessionID
                        )
                    )
                }
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: prepared.transform.responseIDs,
                        code: -32000,
                        message: "expected initialize request",
                        forceBatchArray: prepared.transform.isBatch,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }
        }

        let session = sessionManager.session(id: sessionID)

        if prepared.transform.expectsResponse {
            let started: MCPForwardingService.StartedRequest
            do {
                started = try forwardingService.startRequest(
                    prepared,
                    session: session,
                    on: eventLoop
                )
            } catch {
                return eventLoop.makeSucceededFuture(
                    .mcpError(
                        id: nil,
                        ids: [],
                        code: -32600,
                        message: "missing id",
                        forceBatchArray: false,
                        sessionID: sessionID,
                        prefersEventStream: prefersEventStream
                    )
                )
            }

            let promise = eventLoop.makePromise(of: HTTPPostResolution.self)
            started.future.whenComplete { result in
                let resolution = self.forwardingService.resolveResponse(
                    result,
                    started: started,
                    sessionID: sessionID
                )
                switch resolution {
                case .success(let responseData):
                    promise.succeed(
                        .responseData(
                            data: responseData,
                            sessionID: sessionID,
                            prefersEventStream: prefersEventStream
                        )
                    )
                case .invalidUpstreamResponse:
                    promise.succeed(
                        .plain(
                            status: .badGateway,
                            body: "invalid upstream response",
                            sessionID: sessionID
                        )
                    )
                case .timeout:
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
            return eventLoop.makeSucceededFuture(
                .empty(status: .accepted, sessionID: sessionID)
            )
        }

        sessionManager.sendUpstream(
            prepared.transform.upstreamData,
            upstreamIndex: prepared.upstreamIndex
        )
        return eventLoop.makeSucceededFuture(
            .empty(status: .accepted, sessionID: sessionID)
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

    private func refreshCodeIssuesRequest(from requestJSON: Any) -> RefreshCodeIssuesRequest? {
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

    private func callInternalTool(
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

    private func listXcodeWindows(
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

    private func forwardOnce(
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

    private func forwardRefreshCodeIssuesRequest(
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
}
