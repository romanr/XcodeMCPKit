import Foundation
import NIO
import NIOConcurrencyHelpers
import ProxyCore

package final class InitializeGate: Sendable {
    package struct PendingInitialize: Sendable {
        package let eventLoop: EventLoop
        package let promise: EventLoopPromise<ByteBuffer>
        package let sessionID: String
        package let sessionGeneration: UInt64
        package let originalID: RPCID
    }

    package struct RegisterDecision: Sendable {
        package let promise: EventLoopPromise<ByteBuffer>?
        package let cachedResult: JSONValue?
        package let shouldSendRequest: Bool
        package let shouldScheduleTimeout: Bool
        package let isShuttingDown: Bool
    }

    package struct SuccessResult: Sendable {
        package let pending: [PendingInitialize]
        package let timeout: Scheduled<Void>?
        package let shouldWarmSecondary: Bool
    }

    package struct FailureResult: Sendable {
        package let pending: [PendingInitialize]
        package let timeout: Scheduled<Void>?
        package let upstreamID: Int64?
        package let shouldRetryEagerInitialize: Bool
    }

    package struct ExitResult: Sendable {
        package let pending: [PendingInitialize]
        package let timeout: Scheduled<Void>?
        package let hadGlobalInit: Bool
        package let wasInFlight: Bool
        package let primaryInitUpstreamID: Int64?
    }

    package struct Snapshot: Sendable {
        package let hasInitResult: Bool
        package let initInFlight: Bool
        package let didWarmSecondary: Bool
        package let shouldRetryEagerInitializePrimaryAfterWarmInitFailure: Bool
        package let isShuttingDown: Bool
    }

    private struct State: Sendable {
        var initResult: JSONValue?
        var initPending: [PendingInitialize] = []
        var initInFlight = false
        var initTimeout: Scheduled<Void>?
        var isShuttingDown = false
        var didWarmSecondary = false
        var primaryInitUpstreamID: Int64?
        var shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    package func beginShutdown() -> (pending: [PendingInitialize], timeout: Scheduled<Void>?) {
        state.withLockedValue { state in
            state.isShuttingDown = true
            state.initInFlight = false
            let pending = state.initPending
            state.initPending.removeAll()
            let timeout = state.initTimeout
            state.initTimeout = nil
            return (pending, timeout)
        }
    }

    package func isInitialized() -> Bool {
        state.withLockedValue { $0.initResult != nil }
    }

    package func beginEagerInitializePrimary() -> (
        shouldSendRequest: Bool,
        shouldScheduleTimeout: Bool
    ) {
        state.withLockedValue { state in
            guard state.initResult == nil, !state.initInFlight, !state.isShuttingDown else {
                return (false, false)
            }
            state.initInFlight = true
            return (true, true)
        }
    }

    package func setPrimaryInitUpstreamID(_ upstreamID: Int64) {
        state.withLockedValue { state in
            state.primaryInitUpstreamID = upstreamID
        }
    }

    package func registerInitialize(
        sessionID: String,
        sessionGeneration: UInt64,
        originalID: RPCID,
        on eventLoop: EventLoop
    ) -> RegisterDecision {
        state.withLockedValue { state in
            if state.isShuttingDown {
                return RegisterDecision(
                    promise: nil,
                    cachedResult: nil,
                    shouldSendRequest: false,
                    shouldScheduleTimeout: false,
                    isShuttingDown: true
                )
            }

            if let initResult = state.initResult {
                return RegisterDecision(
                    promise: nil,
                    cachedResult: initResult,
                    shouldSendRequest: false,
                    shouldScheduleTimeout: false,
                    isShuttingDown: false
                )
            }

            let promise = eventLoop.makePromise(of: ByteBuffer.self)
            state.initPending.append(
                PendingInitialize(
                    eventLoop: eventLoop,
                    promise: promise,
                    sessionID: sessionID,
                    sessionGeneration: sessionGeneration,
                    originalID: originalID
                )
            )

            if state.initInFlight {
                return RegisterDecision(
                    promise: promise,
                    cachedResult: nil,
                    shouldSendRequest: false,
                    shouldScheduleTimeout: false,
                    isShuttingDown: false
                )
            }

            state.initInFlight = true
            return RegisterDecision(
                promise: promise,
                cachedResult: nil,
                shouldSendRequest: true,
                shouldScheduleTimeout: true,
                isShuttingDown: false
            )
        }
    }

    package func completePrimaryInitializeSuccess(result: JSONValue) -> SuccessResult? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            if state.initResult == nil {
                state.initResult = result
            }
            state.initInFlight = false
            state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
            let timeout = state.initTimeout
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            state.primaryInitUpstreamID = nil
            let shouldWarmSecondary = !state.didWarmSecondary
            if shouldWarmSecondary {
                state.didWarmSecondary = true
            }
            return SuccessResult(
                pending: pending,
                timeout: timeout,
                shouldWarmSecondary: shouldWarmSecondary
            )
        }
    }

    package func completePrimaryInitializeFailure() -> FailureResult? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            let shouldRetryEagerInitialize =
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure
                && state.initResult == nil
            if shouldRetryEagerInitialize {
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
            }
            state.initInFlight = false
            let timeout = state.initTimeout
            state.initTimeout = nil
            let pending = state.initPending
            state.initPending.removeAll()
            let upstreamID = state.primaryInitUpstreamID
            state.primaryInitUpstreamID = nil
            return FailureResult(
                pending: pending,
                timeout: timeout,
                upstreamID: upstreamID,
                shouldRetryEagerInitialize: shouldRetryEagerInitialize
            )
        }
    }

    package func replaceInitTimeout(_ timeout: Scheduled<Void>) -> Scheduled<Void>? {
        state.withLockedValue { state in
            let existing = state.initTimeout
            state.initTimeout = timeout
            return existing
        }
    }

    package func handleUpstreamExit(upstreamIndex: Int) -> ExitResult? {
        state.withLockedValue { state in
            guard !state.isShuttingDown else { return nil }
            let result = ExitResult(
                pending: state.initPending,
                timeout: state.initTimeout,
                hadGlobalInit: state.initResult != nil,
                wasInFlight: state.initInFlight,
                primaryInitUpstreamID: state.primaryInitUpstreamID
            )

            if upstreamIndex == 0, state.initInFlight {
                state.initInFlight = false
                state.initTimeout = nil
                state.initPending.removeAll()
                state.primaryInitUpstreamID = nil
            }

            return result
        }
    }

    package func resetCachedInitializeResult() {
        state.withLockedValue { state in
            state.initResult = nil
            state.didWarmSecondary = false
        }
    }

    package func setShouldRetryEagerInitializePrimaryAfterWarmInitFailure(_ shouldRetry: Bool) {
        state.withLockedValue { state in
            state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = shouldRetry
        }
    }

    package func consumeRetryAfterWarmInitFailureIfNeeded() -> Bool {
        state.withLockedValue { state in
            let shouldRetry =
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure
                && state.initResult == nil
            if shouldRetry {
                state.shouldRetryEagerInitializePrimaryAfterWarmInitFailure = false
            }
            return shouldRetry
        }
    }

    package func snapshot() -> Snapshot {
        state.withLockedValue { state in
            Snapshot(
                hasInitResult: state.initResult != nil,
                initInFlight: state.initInFlight,
                didWarmSecondary: state.didWarmSecondary,
                shouldRetryEagerInitializePrimaryAfterWarmInitFailure: state
                    .shouldRetryEagerInitializePrimaryAfterWarmInitFailure,
                isShuttingDown: state.isShuttingDown
            )
        }
    }

    package func pendingSessionIDs() -> [String] {
        state.withLockedValue { state in
            Array(Set(state.initPending.map(\.sessionID))).sorted()
        }
    }
}
