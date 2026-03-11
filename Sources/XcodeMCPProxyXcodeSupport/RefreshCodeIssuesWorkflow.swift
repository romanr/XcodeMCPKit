import Foundation
import Logging
import NIO
import XcodeMCPProxyCore

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
    case timeout(responseIds: [RPCId], isBatch: Bool)
    case upstreamUnavailable(responseIds: [RPCId], isBatch: Bool)
    case overloaded(responseIds: [RPCId], isBatch: Bool)
    case invalidRequest
    case invalidUpstreamResponse
}

package struct RefreshCodeIssuesWorkflow {
    package typealias WindowsProvider = @Sendable (_ sessionId: String, _ eventLoop: EventLoop) async -> [XcodeWindowInfo]?
    package typealias Forwarder =
        @Sendable (_ bodyData: Data, _ sessionId: String, _ requestIDs: [RPCId], _ requestIsBatch: Bool, _ eventLoop: EventLoop) async -> RefreshForwardAttemptResult

    package static let retryDelaysNanos: [UInt64] = [
        200_000_000,
        500_000_000,
    ]

    private let coordinator: RefreshCodeIssuesCoordinator
    private let warmupDriver: XcodeEditorWarmupDriver
    private let logger: Logger

    package init(
        coordinator: RefreshCodeIssuesCoordinator,
        warmupDriver: XcodeEditorWarmupDriver,
        logger: Logger
    ) {
        self.coordinator = coordinator
        self.warmupDriver = warmupDriver
        self.logger = logger
    }

    package func run(
        refreshRequest: RefreshCodeIssuesRequest,
        bodyData: Data,
        sessionId: String,
        requestIDs: [RPCId],
        requestIsBatch: Bool,
        eventLoop: EventLoop,
        windowsProvider: WindowsProvider,
        forwarder: Forwarder
    ) async -> RefreshForwardAttemptResult {
        do {
            return try await coordinator.withPermit(key: refreshRequest.queueKey) { permit in
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
                    metadata: baseMetadata.merging(queueMetadata, uniquingKeysWith: { _, new in new })
                )

                let warmupResult = await warmupDriver.warmUp(
                    tabIdentifier: refreshRequest.tabIdentifier,
                    filePath: refreshRequest.filePath,
                    sessionId: sessionId,
                    eventLoop: eventLoop,
                    windowsProvider: windowsProvider
                )
                let warmupMetadata = baseMetadata.merging(
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

                resultLoop: for attemptIndex in 0...Self.retryDelaysNanos.count {
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

                    let result = await forwarder(
                        bodyData,
                        sessionId,
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
