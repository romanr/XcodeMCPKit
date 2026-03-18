import Foundation
import NIO

package enum MCPMethodDispatcher {
    private static let capped20sMethods: Set<String> = [
        "tools/list",
        "resources/list",
        "resources/templates/list",
    ]
    private static let initializeFallbackTimeoutSeconds: TimeInterval = 60

    package static func timeoutForInitialize(defaultSeconds: TimeInterval) -> TimeAmount? {
        let effectiveDefault = defaultSeconds > 0 ? defaultSeconds : initializeFallbackTimeoutSeconds
        return timeout(defaultSeconds: effectiveDefault, capSeconds: initializeFallbackTimeoutSeconds)
    }

    package static func timeoutForMethod(
        _ method: String?,
        defaultSeconds: TimeInterval
    ) -> TimeAmount? {
        guard let method else {
            return makeRequestTimeout(defaultSeconds)
        }
        if method == "initialize" {
            return timeout(defaultSeconds: defaultSeconds, capSeconds: 60)
        }
        if capped20sMethods.contains(method) {
            return timeout(defaultSeconds: defaultSeconds, capSeconds: 20)
        }
        return makeRequestTimeout(defaultSeconds)
    }

    private static func timeout(
        defaultSeconds: TimeInterval,
        capSeconds: TimeInterval
    ) -> TimeAmount? {
        guard defaultSeconds > 0 else { return nil }
        return makeRequestTimeout(min(defaultSeconds, capSeconds))
    }
}
