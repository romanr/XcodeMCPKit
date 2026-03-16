import Foundation
import NIOConcurrencyHelpers
import ProxyCore

package struct SessionRecord: Sendable {
    package let context: SessionContext
    package let generation: UInt64
    package var pinnedUpstreamIndex: Int?
    package var initializeUpstreamIndex: Int?
    package var preferInitializeUpstreamOnNextPin: Bool
    package var didReceiveInitializeUpstreamMessage: Bool
}

package final class SessionStore: Sendable {
    private struct State: Sendable {
        var sessions: [String: SessionRecord] = [:]
        var nextGeneration: UInt64 = 0
    }

    private let state = NIOLockedValueBox(State())
    private let config: ProxyConfig

    package init(config: ProxyConfig) {
        self.config = config
    }

    package func session(id: String) -> SessionContext {
        state.withLockedValue { state in
            if let existing = state.sessions[id] {
                return existing.context
            }
            let context = SessionContext(id: id, config: config)
            state.nextGeneration &+= 1
            state.sessions[id] = SessionRecord(
                context: context,
                generation: state.nextGeneration,
                pinnedUpstreamIndex: nil,
                initializeUpstreamIndex: nil,
                preferInitializeUpstreamOnNextPin: false,
                didReceiveInitializeUpstreamMessage: false
            )
            return context
        }
    }

    package func hasSession(id: String) -> Bool {
        state.withLockedValue { $0.sessions[id] != nil }
    }

    package func removeSession(id: String) -> SessionContext? {
        state.withLockedValue { $0.sessions.removeValue(forKey: id)?.context }
    }

    package func generation(of sessionID: String) -> UInt64? {
        state.withLockedValue { $0.sessions[sessionID]?.generation }
    }

    package func pinnedUpstreamIndex(for sessionID: String) -> Int? {
        state.withLockedValue { $0.sessions[sessionID]?.pinnedUpstreamIndex }
    }

    package func preferredInitializeUpstreamIndex(for sessionID: String) -> Int? {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionID],
                record.pinnedUpstreamIndex == nil,
                (record.preferInitializeUpstreamOnNextPin || record.didReceiveInitializeUpstreamMessage),
                let upstreamIndex = record.initializeUpstreamIndex
            else {
                return nil
            }
            return upstreamIndex
        }
    }

    package func hintedUpstreamIndex(for sessionID: String) -> Int? {
        state.withLockedValue { state in
            if let pinned = state.sessions[sessionID]?.pinnedUpstreamIndex {
                return pinned
            }
            return state.sessions[sessionID]?.initializeUpstreamIndex
        }
    }

    package func clearRoutingState(for sessionID: String) {
        state.withLockedValue { state in
            state.sessions[sessionID]?.pinnedUpstreamIndex = nil
            state.sessions[sessionID]?.initializeUpstreamIndex = nil
            state.sessions[sessionID]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionID]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    package func pinSession(_ sessionID: String, to upstreamIndex: Int) {
        state.withLockedValue { state in
            state.sessions[sessionID]?.pinnedUpstreamIndex = upstreamIndex
            state.sessions[sessionID]?.initializeUpstreamIndex = nil
            state.sessions[sessionID]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionID]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    package func clearInitializeHintIfUnpinned(for sessionID: String) {
        state.withLockedValue { state in
            guard state.sessions[sessionID]?.pinnedUpstreamIndex == nil else { return }
            state.sessions[sessionID]?.initializeUpstreamIndex = nil
            state.sessions[sessionID]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionID]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    package func setInitializeUpstreamIfNeeded(
        sessionID: String,
        upstreamIndex: Int,
        preferOnNextPin: Bool
    ) {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionID] else { return }
            if record.pinnedUpstreamIndex == nil {
                state.sessions[sessionID]?.initializeUpstreamIndex = upstreamIndex
                state.sessions[sessionID]?.preferInitializeUpstreamOnNextPin = preferOnNextPin
                state.sessions[sessionID]?.didReceiveInitializeUpstreamMessage = false
            } else {
                state.sessions[sessionID]?.initializeUpstreamIndex = nil
                state.sessions[sessionID]?.preferInitializeUpstreamOnNextPin = false
                state.sessions[sessionID]?.didReceiveInitializeUpstreamMessage = false
            }
        }
    }

    package func clearInitializeUpstreamIndex(
        sessionID: String,
        onlyIfGeneration sessionGeneration: UInt64? = nil
    ) {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionID] else { return }
            if let sessionGeneration, record.generation != sessionGeneration {
                return
            }
            state.sessions[sessionID]?.initializeUpstreamIndex = nil
            state.sessions[sessionID]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionID]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    package func sessionStillMatchesPendingInitialize(
        sessionID: String,
        sessionGeneration: UInt64
    ) -> Bool {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionID] else { return false }
            return record.generation == sessionGeneration
        }
    }

    package func clearPinnedSessions(forUpstreamIndex upstreamIndex: Int) -> Int {
        state.withLockedValue { state in
            let keys = Array(state.sessions.keys)
            var cleared = 0
            for key in keys {
                if state.sessions[key]?.pinnedUpstreamIndex == upstreamIndex {
                    state.sessions[key]?.pinnedUpstreamIndex = nil
                    state.sessions[key]?.initializeUpstreamIndex = nil
                    state.sessions[key]?.preferInitializeUpstreamOnNextPin = false
                    cleared += 1
                } else if state.sessions[key]?.initializeUpstreamIndex == upstreamIndex {
                    state.sessions[key]?.initializeUpstreamIndex = nil
                    state.sessions[key]?.preferInitializeUpstreamOnNextPin = false
                }
            }
            return cleared
        }
    }

    package func routedTargets(forUpstreamIndex upstreamIndex: Int) -> [SessionContext] {
        state.withLockedValue { state in
            var targets: [SessionContext] = []
            targets.reserveCapacity(state.sessions.count)
            let keys = Array(state.sessions.keys)
            for key in keys {
                guard let record = state.sessions[key] else { continue }
                if record.pinnedUpstreamIndex == upstreamIndex {
                    targets.append(record.context)
                } else if record.pinnedUpstreamIndex == nil
                    && record.initializeUpstreamIndex == upstreamIndex
                {
                    state.sessions[key]?.didReceiveInitializeUpstreamMessage = true
                    targets.append(record.context)
                }
            }
            return targets
        }
    }

    package func markDidReceiveInitializeUpstreamMessage(for sessionID: String) {
        state.withLockedValue { state in
            state.sessions[sessionID]?.didReceiveInitializeUpstreamMessage = true
        }
    }

    package func requestQueueSnapshots() -> [SessionRequestQueueDebugSnapshot] {
        state.withLockedValue { state in
            state.sessions
                .values
                .map { $0.context.requestSequencer.debugSnapshot() }
                .sorted { $0.sessionID < $1.sessionID }
        }
    }

    func testSnapshot(id: String) -> RuntimeCoordinator.TestSnapshot.Session? {
        state.withLockedValue { state in
            guard let record = state.sessions[id] else { return nil }
            return RuntimeCoordinator.TestSnapshot.Session(
                generation: record.generation,
                pinnedUpstreamIndex: record.pinnedUpstreamIndex,
                initializeUpstreamIndex: record.initializeUpstreamIndex,
                preferInitializeUpstreamOnNextPin: record.preferInitializeUpstreamOnNextPin,
                didReceiveInitializeUpstreamMessage: record.didReceiveInitializeUpstreamMessage
            )
        }
    }
}
