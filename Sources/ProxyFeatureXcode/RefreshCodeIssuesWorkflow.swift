import Foundation
import Logging
import NIO
import ProxyCore

package struct RefreshCodeIssuesRequest: Sendable {
    package static let toolName = "XcodeRefreshCodeIssuesInFile"
    package static let globalQueueKey = "__global__"

    package let tabIdentifier: String?
    package let filePath: String?

    package init(tabIdentifier: String?, filePath: String?) {
        self.tabIdentifier = tabIdentifier
        self.filePath = filePath
    }

    package var queueKey: String {
        guard let tabIdentifier, tabIdentifier.isEmpty == false else {
            return Self.globalQueueKey
        }
        return tabIdentifier
    }
}

package enum RefreshForwardAttemptResult: Sendable {
    case success(Data)
    case timeout(responseIDs: [RPCID], isBatch: Bool)
    case upstreamUnavailable(responseIDs: [RPCID], isBatch: Bool)
    case overloaded(responseIDs: [RPCID], isBatch: Bool)
    case invalidRequest
    case invalidUpstreamResponse
}

package struct RefreshCodeIssuesWorkflow {
    package typealias WindowsProvider =
        @Sendable (_ sessionID: String, _ eventLoop: EventLoop, _ upstreamIndexOverride: Int?) async -> [XcodeWindowInfo]?
    package typealias InternalUpstreamChooser = @Sendable (_ sessionID: String) async -> Int?
    package typealias InternalToolCaller =
        @Sendable (_ name: String, _ arguments: [String: Any], _ sessionID: String, _ eventLoop: EventLoop, _ upstreamIndexOverride: Int?) async -> [String: Any]?
    package typealias Forwarder =
        @Sendable (_ bodyData: Data, _ sessionID: String, _ requestIDs: [RPCID], _ requestIsBatch: Bool, _ eventLoop: EventLoop) async -> RefreshForwardAttemptResult

    package static let retryDelaysNanos: [UInt64] = [
        200_000_000,
        500_000_000,
    ]

    private let mode: RefreshCodeIssuesMode
    private let coordinator: RefreshCodeIssuesCoordinator
    private let targetResolver: RefreshCodeIssuesTargetResolver
    private let logger: Logger

    package init(
        mode: RefreshCodeIssuesMode,
        coordinator: RefreshCodeIssuesCoordinator,
        targetResolver: RefreshCodeIssuesTargetResolver,
        logger: Logger
    ) {
        self.mode = mode
        self.coordinator = coordinator
        self.targetResolver = targetResolver
        self.logger = logger
    }

    package func run(
        refreshRequest: RefreshCodeIssuesRequest,
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider,
        internalUpstreamChooser: InternalUpstreamChooser,
        internalToolCaller: InternalToolCaller,
        forwarder: Forwarder
    ) async -> RefreshForwardAttemptResult {
        let baseMetadata: Logger.Metadata = [
            "session": .string(sessionID),
            "mode": .string(mode.rawValue),
            "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
            "queue_key": .string(refreshRequest.queueKey),
        ]

        do {
            return try await coordinator.withPermit(key: refreshRequest.queueKey) { permit in
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

                if mode == .proxy,
                    let proxyResponseData = await runProxyRefresh(
                        refreshRequest: refreshRequest,
                        sessionID: sessionID,
                        requestIDs: requestIDs,
                        eventLoop: eventLoop,
                        baseMetadata: baseMetadata,
                        windowsProvider: windowsProvider,
                        internalUpstreamChooser: internalUpstreamChooser,
                        internalToolCaller: internalToolCaller
                    )
                {
                    return .success(proxyResponseData)
                }

                return await runForwardAttempts(
                    bodyData: bodyData,
                    sessionID: sessionID,
                    requestIDs: requestIDs,
                    requestIsBatch: requestIsBatch,
                    eventLoop: eventLoop,
                    baseMetadata: baseMetadata,
                    forwarder: forwarder
                )
            }
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueLimitExceeded {
            logger.warning(
                "Rejected refresh code issues request because queue is full",
                metadata: [
                    "session": .string(sessionID),
                    "mode": .string(mode.rawValue),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            return .overloaded(responseIDs: requestIDs, isBatch: requestIsBatch)
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueWaitTimedOut {
            logger.warning(
                "Rejected refresh code issues request after queue wait timeout",
                metadata: [
                    "session": .string(sessionID),
                    "mode": .string(mode.rawValue),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            return .overloaded(responseIDs: requestIDs, isBatch: requestIsBatch)
        } catch is CancellationError {
            logger.debug(
                "Cancelled queued refresh code issues request",
                metadata: [
                    "session": .string(sessionID),
                    "mode": .string(mode.rawValue),
                    "tab_identifier": .string(refreshRequest.tabIdentifier ?? "none"),
                    "queue_key": .string(refreshRequest.queueKey),
                ]
            )
            return .overloaded(responseIDs: requestIDs, isBatch: requestIsBatch)
        } catch {
            return .invalidRequest
        }
    }

    private func runProxyRefresh(
        refreshRequest: RefreshCodeIssuesRequest,
        sessionID: String,
        requestIDs: [RPCID],
        eventLoop: EventLoop,
        baseMetadata: Logger.Metadata,
        windowsProvider: WindowsProvider,
        internalUpstreamChooser: InternalUpstreamChooser,
        internalToolCaller: InternalToolCaller
    ) async -> Data? {
        guard let internalUpstreamIndex = await internalUpstreamChooser(sessionID) else {
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: baseMetadata.merging(
                    ["fallback_reason": .string("internal upstream unavailable")],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        let resolution = await targetResolver.resolve(
            tabIdentifier: refreshRequest.tabIdentifier,
            filePath: refreshRequest.filePath,
            sessionID: sessionID,
            eventLoop: eventLoop,
            upstreamIndex: internalUpstreamIndex,
            windowsProvider: { sessionID, eventLoop in
                await windowsProvider(sessionID, eventLoop, internalUpstreamIndex)
            }
        )
        let metadata = baseMetadata.merging(
            [
                "workspace_path": .string(resolution.workspacePath ?? "none"),
                "requested_file_path": .string(refreshRequest.filePath ?? "none"),
                "resolved_file_path": .string(resolution.resolvedFilePath ?? "none"),
                "internal_upstream": .string("\(internalUpstreamIndex)"),
            ],
            uniquingKeysWith: { _, new in new }
        )

        guard let target = resolution.target else {
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    ["fallback_reason": .string(resolution.failureReason ?? "unknown")],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        let arguments: [String: Any] = [
            "tabIdentifier": refreshRequest.tabIdentifier ?? "",
            "severity": "remark",
            "glob": "**/" + Self.escapeGlobLiteralPath(target.workspaceRelativePath),
        ]
        guard let navigatorResult = await internalToolCaller(
            "XcodeListNavigatorIssues",
            arguments,
            sessionID,
            eventLoop,
            internalUpstreamIndex
        ) else {
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    [
                        "fallback_reason": .string("navigator issues unavailable"),
                        "resolved_target": .string(target.resolvedFilePath),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }
        guard let filteredNavigatorResult = Self.filterNavigatorIssuesResult(
            navigatorResult,
            matchingResolvedFilePath: target.resolvedFilePath
        ) else {
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    [
                        "fallback_reason": .string("navigator issues payload malformed"),
                        "resolved_target": .string(target.resolvedFilePath),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }
        guard let responseID = requestIDs.first,
            let responseData = Self.makeToolResponseData(
                id: responseID,
                result: filteredNavigatorResult
            )
        else {
            logger.debug(
                "Refresh code issues proxy mode fell back to upstream refresh",
                metadata: metadata.merging(
                    [
                        "fallback_reason": .string("invalid proxy response encoding"),
                        "resolved_target": .string(target.resolvedFilePath),
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            return nil
        }

        logger.debug(
            "Refresh code issues served via proxy navigator issues",
            metadata: metadata.merging(
                ["resolved_target": .string(target.resolvedFilePath)],
                uniquingKeysWith: { _, new in new }
            )
        )
        return responseData
    }

    private func runForwardAttempts(
        bodyData: Data,
        sessionID: String,
        requestIDs: [RPCID],
        requestIsBatch: Bool,
        eventLoop: EventLoop,
        baseMetadata: Logger.Metadata,
        forwarder: Forwarder
    ) async -> RefreshForwardAttemptResult {
        var finalResult: RefreshForwardAttemptResult = .invalidRequest

        resultLoop: for attemptIndex in 0...Self.retryDelaysNanos.count {
            let attempt = attemptIndex + 1
            let attemptMetadata = baseMetadata.merging(
                ["attempt": .string("\(attempt)")],
                uniquingKeysWith: { _, new in new }
            )
            let result = await forwarder(
                bodyData,
                sessionID,
                requestIDs,
                requestIsBatch,
                eventLoop
            )

            switch result {
            case .success(let responseData):
                let retryable = Self.isRetryableRefreshCodeIssuesFailure(responseData)
                if retryable, attemptIndex < Self.retryDelaysNanos.count {
                    let delayNanos = Self.retryDelaysNanos[attemptIndex]
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

        return finalResult
    }

    private static func makeToolResponseData(id: RPCID, result: [String: Any]) -> Data? {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.value.foundationObject,
            "result": result,
        ]
        guard JSONSerialization.isValidJSONObject(response) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: response, options: [])
    }

    private static func filterNavigatorIssuesResult(
        _ navigatorResult: [String: Any],
        matchingResolvedFilePath resolvedFilePath: String
    ) -> [String: Any]? {
        guard
            let structuredContent = navigatorResult["structuredContent"] as? [String: Any],
            let issues = structuredContent["issues"] as? [[String: Any]]
        else {
            return nil
        }

        let filteredIssues = issues.filter { issue in
            guard let path = issue["path"] as? String else { return false }
            return normalizedIssuePath(path) == normalizedIssuePath(resolvedFilePath)
        }

        var filteredStructuredContent = structuredContent
        filteredStructuredContent["issues"] = filteredIssues
        filteredStructuredContent["totalFound"] = filteredIssues.count

        var filteredResult = navigatorResult
        filteredResult["structuredContent"] = filteredStructuredContent

        let contentItem: [String: Any] = [
            "type": "text",
            "text": navigatorIssuesText(from: filteredStructuredContent),
        ]
        filteredResult["content"] = [contentItem]
        return filteredResult
    }

    private static func navigatorIssuesText(from structuredContent: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(structuredContent),
            let data = try? JSONSerialization.data(withJSONObject: structuredContent, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"issues\":[],\"totalFound\":0,\"truncated\":false}"
        }
        return text
    }

    private static func normalizedIssuePath(_ path: String) -> String {
        let symlinkResolvedPath = (path as NSString).resolvingSymlinksInPath
        return URL(fileURLWithPath: symlinkResolvedPath).standardizedFileURL.path
    }

    private static func escapeGlobLiteralPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "[", with: "[[]")
            .replacingOccurrences(of: "]", with: "[]]")
            .replacingOccurrences(of: "*", with: "[*]")
            .replacingOccurrences(of: "?", with: "[?]")
    }

    private static func isRetryableRefreshCodeIssuesFailure(_ responseData: Data) -> Bool {
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
}
