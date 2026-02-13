import Foundation

enum UpstreamHealthState: Sendable {
    case healthy
    case degraded
    case quarantined(untilUptimeNs: UInt64)
}
