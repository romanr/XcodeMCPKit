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

package final class SessionRegistry: Sendable {
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

    package func generation(of sessionId: String) -> UInt64? {
        state.withLockedValue { $0.sessions[sessionId]?.generation }
    }

    package func pinnedUpstreamIndex(for sessionId: String) -> Int? {
        state.withLockedValue { $0.sessions[sessionId]?.pinnedUpstreamIndex }
    }

    package func preferredInitializeUpstreamIndex(for sessionId: String) -> Int? {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionId],
                record.pinnedUpstreamIndex == nil,
                (record.preferInitializeUpstreamOnNextPin || record.didReceiveInitializeUpstreamMessage),
                let upstreamIndex = record.initializeUpstreamIndex
            else {
                return nil
            }
            return upstreamIndex
        }
    }

    package func hintedUpstreamIndex(for sessionId: String) -> Int? {
        state.withLockedValue { state in
            if let pinned = state.sessions[sessionId]?.pinnedUpstreamIndex {
                return pinned
            }
            return state.sessions[sessionId]?.initializeUpstreamIndex
        }
    }

    package func clearRoutingState(for sessionId: String) {
        state.withLockedValue { state in
            state.sessions[sessionId]?.pinnedUpstreamIndex = nil
            state.sessions[sessionId]?.initializeUpstreamIndex = nil
            state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    package func pinSession(_ sessionId: String, to upstreamIndex: Int) {
        state.withLockedValue { state in
            state.sessions[sessionId]?.pinnedUpstreamIndex = upstreamIndex
            state.sessions[sessionId]?.initializeUpstreamIndex = nil
            state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    package func clearInitializeHintIfUnpinned(for sessionId: String) {
        state.withLockedValue { state in
            guard state.sessions[sessionId]?.pinnedUpstreamIndex == nil else { return }
            state.sessions[sessionId]?.initializeUpstreamIndex = nil
            state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    package func setInitializeUpstreamIfNeeded(
        sessionId: String,
        upstreamIndex: Int,
        preferOnNextPin: Bool
    ) {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionId] else { return }
            if record.pinnedUpstreamIndex == nil {
                state.sessions[sessionId]?.initializeUpstreamIndex = upstreamIndex
                state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = preferOnNextPin
                state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
            } else {
                state.sessions[sessionId]?.initializeUpstreamIndex = nil
                state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
                state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
            }
        }
    }

    package func clearInitializeUpstreamIndex(
        sessionId: String,
        onlyIfGeneration sessionGeneration: UInt64? = nil
    ) {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionId] else { return }
            if let sessionGeneration, record.generation != sessionGeneration {
                return
            }
            state.sessions[sessionId]?.initializeUpstreamIndex = nil
            state.sessions[sessionId]?.preferInitializeUpstreamOnNextPin = false
            state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = false
        }
    }

    package func sessionStillMatchesPendingInitialize(
        sessionId: String,
        sessionGeneration: UInt64
    ) -> Bool {
        state.withLockedValue { state in
            guard let record = state.sessions[sessionId] else { return false }
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

    package func markDidReceiveInitializeUpstreamMessage(for sessionId: String) {
        state.withLockedValue { state in
            state.sessions[sessionId]?.didReceiveInitializeUpstreamMessage = true
        }
    }

    func testSnapshot(id: String) -> SessionManager.TestSnapshot.Session? {
        state.withLockedValue { state in
            guard let record = state.sessions[id] else { return nil }
            return SessionManager.TestSnapshot.Session(
                generation: record.generation,
                pinnedUpstreamIndex: record.pinnedUpstreamIndex,
                initializeUpstreamIndex: record.initializeUpstreamIndex,
                preferInitializeUpstreamOnNextPin: record.preferInitializeUpstreamOnNextPin,
                didReceiveInitializeUpstreamMessage: record.didReceiveInitializeUpstreamMessage
            )
        }
    }
}
