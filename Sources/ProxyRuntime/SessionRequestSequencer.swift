import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import ProxyCore

package struct SessionRequestQueueDebugSnapshot: Codable, Sendable {
    package let sessionID: String
    package let hasActiveRequest: Bool
    package let currentRequestLabel: String?
    package let pendingRequestCount: Int

    package init(
        sessionID: String,
        hasActiveRequest: Bool,
        currentRequestLabel: String?,
        pendingRequestCount: Int
    ) {
        self.sessionID = sessionID
        self.hasActiveRequest = hasActiveRequest
        self.currentRequestLabel = currentRequestLabel
        self.pendingRequestCount = pendingRequestCount
    }
}

package final class SessionRequestSequencer: Sendable {
    private struct PendingRequest: Sendable {
        let label: String?
        let eventLoop: EventLoop
        let promise: EventLoopPromise<Void>
    }

    private struct State: Sendable {
        var hasActiveRequest = false
        var currentRequestLabel: String?
        var pendingRequests: [PendingRequest] = []
    }

    private enum AcquireState {
        case immediate
        case queued(activeLabel: String?, pendingCount: Int)
    }

    private let sessionID: String
    private let logger: Logger
    private let state = NIOLockedValueBox(State())

    package init(
        sessionID: String,
        logger: Logger = ProxyLogging.make("session.queue")
    ) {
        self.sessionID = sessionID
        self.logger = logger
    }

    package func acquire(label: String?, on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let promise = eventLoop.makePromise(of: Void.self)
        let acquireState = state.withLockedValue { state -> AcquireState in
            if state.hasActiveRequest == false {
                state.hasActiveRequest = true
                state.currentRequestLabel = label
                return .immediate
            }

            state.pendingRequests.append(
                PendingRequest(
                    label: label,
                    eventLoop: eventLoop,
                    promise: promise
                )
            )
            return .queued(
                activeLabel: state.currentRequestLabel,
                pendingCount: state.pendingRequests.count
            )
        }

        switch acquireState {
        case .immediate:
            logger.debug(
                "Started session-scoped upstream request",
                metadata: [
                    "session": .string(sessionID),
                    "label": .string(label ?? "unknown"),
                    "pending_count": .string("0"),
                ]
            )
            promise.succeed(())

        case .queued(let activeLabel, let pendingCount):
            logger.debug(
                "Queued session-scoped upstream request",
                metadata: [
                    "session": .string(sessionID),
                    "label": .string(label ?? "unknown"),
                    "active_label": .string(activeLabel ?? "none"),
                    "pending_count": .string("\(pendingCount)"),
                ]
            )
        }

        return promise.futureResult
    }

    package func finishCurrentRequest() {
        let nextRequest = state.withLockedValue { state -> PendingRequest? in
            if state.pendingRequests.isEmpty {
                let currentLabel = state.currentRequestLabel
                logger.debug(
                    "Completed session-scoped upstream request",
                    metadata: [
                        "session": .string(sessionID),
                        "label": .string(currentLabel ?? "unknown"),
                        "pending_count": .string("0"),
                    ]
                )
                state.hasActiveRequest = false
                state.currentRequestLabel = nil
                return nil
            }

            let next = state.pendingRequests.removeFirst()
            state.hasActiveRequest = true
            state.currentRequestLabel = next.label
            logger.debug(
                "Dequeued session-scoped upstream request",
                metadata: [
                    "session": .string(sessionID),
                    "label": .string(next.label ?? "unknown"),
                    "pending_count": .string("\(state.pendingRequests.count)"),
                ]
            )
            return next
        }

        guard let nextRequest else { return }
        nextRequest.eventLoop.execute {
            nextRequest.promise.succeed(())
        }
    }

    package func debugSnapshot() -> SessionRequestQueueDebugSnapshot {
        state.withLockedValue { state in
            SessionRequestQueueDebugSnapshot(
                sessionID: sessionID,
                hasActiveRequest: state.hasActiveRequest,
                currentRequestLabel: state.currentRequestLabel,
                pendingRequestCount: state.pendingRequests.count
            )
        }
    }
}
