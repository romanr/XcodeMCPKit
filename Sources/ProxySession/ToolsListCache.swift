import Foundation
import NIOConcurrencyHelpers
import ProxyCore

package final class ToolsListCache: Sendable {
    private struct State: Sendable {
        var cachedResult: JSONValue?
        var warmupInFlight = false
        var internalSessionId: String?
    }

    private let state = NIOLockedValueBox(State())

    package init() {}

    package func cachedResult() -> JSONValue? {
        state.withLockedValue { $0.cachedResult }
    }

    package func setCachedResult(_ result: JSONValue) {
        state.withLockedValue { $0.cachedResult = result }
    }

    package func beginWarmupIfNeeded(isEnabled: Bool, isInitialized: Bool) -> Bool {
        guard isEnabled, isInitialized else { return false }
        return state.withLockedValue { state in
            if state.cachedResult != nil || state.warmupInFlight {
                return false
            }
            state.warmupInFlight = true
            return true
        }
    }

    package func endWarmup() {
        state.withLockedValue { $0.warmupInFlight = false }
    }

    package func snapshot() -> (cachedResult: JSONValue?, warmupInFlight: Bool) {
        state.withLockedValue { ($0.cachedResult, $0.warmupInFlight) }
    }

    package func internalSessionId(hasSession: (String) -> Bool) -> String {
        if let existing = state.withLockedValue({ $0.internalSessionId }) {
            return existing
        }

        var candidate: String
        repeat {
            candidate = "__tools_list_warmup__:" + UUID().uuidString
        } while hasSession(candidate)

        return state.withLockedValue { state in
            if let existing = state.internalSessionId {
                return existing
            }
            state.internalSessionId = candidate
            return candidate
        }
    }
}
