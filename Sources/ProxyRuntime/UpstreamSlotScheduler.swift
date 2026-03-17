import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import ProxyCore

package struct UpstreamSlotSchedulerDebugSnapshot: Codable, Sendable {
    package let queuedRequestCount: Int
    package let activeLeaseCountByUpstream: [Int: Int]

    package init(
        queuedRequestCount: Int,
        activeLeaseCountByUpstream: [Int: Int]
    ) {
        self.queuedRequestCount = queuedRequestCount
        self.activeLeaseCountByUpstream = activeLeaseCountByUpstream
    }
}

package final class UpstreamSlotScheduler: Sendable {
    private struct PendingRequest: Sendable {
        let leaseID: RequestLeaseID
        let descriptor: SessionPipelineRequestDescriptor
        let eventLoop: EventLoop
        let preferredUpstreamIndex: Int?
        let start: @Sendable (Int) -> Void
        let failUnavailable: @Sendable () -> Void
        let failCancelled: @Sendable () -> Void
    }

    private struct State: Sendable {
        var pendingRequests: [PendingRequest] = []
        var activeLeaseIDsByUpstream: [Int: RequestLeaseID] = [:]
        var capacityByUpstream: [Int: Int] = [:]
    }

    private let logger: Logger
    private let state: NIOLockedValueBox<State>
    private let canUseUpstream: @Sendable (Int) -> Bool
    private let selectUpstream: @Sendable (Set<Int>) -> Int?

    package init(
        upstreamCount: Int,
        defaultCapacity: Int,
        logger: Logger = ProxyLogging.make("upstream.scheduler"),
        canUseUpstream: @escaping @Sendable (Int) -> Bool,
        selectUpstream: @escaping @Sendable (Set<Int>) -> Int?
    ) {
        self.logger = logger
        self.canUseUpstream = canUseUpstream
        self.selectUpstream = selectUpstream
        self.state = NIOLockedValueBox(
            State(
                pendingRequests: [],
                activeLeaseIDsByUpstream: [:],
                capacityByUpstream: Dictionary(
                    uniqueKeysWithValues: (0..<upstreamCount).map { ($0, defaultCapacity) }
                )
            )
        )
    }

    package func enqueueRequest(
        leaseID: RequestLeaseID,
        descriptor: SessionPipelineRequestDescriptor,
        on eventLoop: EventLoop,
        preferredUpstreamIndex: Int? = nil,
        starter: @escaping @Sendable (Int) -> Void,
        failUnavailable: @escaping @Sendable () -> Void,
        failCancelled: @escaping @Sendable () -> Void
    ) {
        let request = PendingRequest(
            leaseID: leaseID,
            descriptor: descriptor,
            eventLoop: eventLoop,
            preferredUpstreamIndex: preferredUpstreamIndex,
            start: starter,
            failUnavailable: failUnavailable,
            failCancelled: failCancelled
        )

        state.withLockedValue { state in
            state.pendingRequests.append(request)
        }
        dispatchQueuedRequestsIfPossible()
    }

    package func releaseUpstreamSlot(upstreamIndex: Int, leaseID: RequestLeaseID) {
        let released = state.withLockedValue { state -> Bool in
            guard state.activeLeaseIDsByUpstream[upstreamIndex] == leaseID else { return false }
            state.activeLeaseIDsByUpstream.removeValue(forKey: upstreamIndex)
            return true
        }
        guard released else { return }
        logger.debug(
            "Released upstream slot",
            metadata: [
                "lease_id": .string(leaseID.uuidString),
                "upstream": .string("\(upstreamIndex)"),
            ]
        )
        dispatchQueuedRequestsIfPossible()
    }

    package func failQueuedRequests() {
        let failed = state.withLockedValue { state -> [PendingRequest] in
            let pending = state.pendingRequests
            state.pendingRequests.removeAll()
            return pending
        }
        guard failed.isEmpty == false else { return }

        for request in failed {
            logger.debug(
                "Failing queued request before upstream dispatch",
                metadata: [
                    "lease_id": .string(request.leaseID.uuidString),
                    "label": .string(request.descriptor.label),
                ]
            )
            request.eventLoop.execute {
                request.failUnavailable()
            }
        }
    }

    package func cancelQueuedRequest(leaseID: RequestLeaseID) {
        let removed = state.withLockedValue { state -> PendingRequest? in
            guard let index = state.pendingRequests.firstIndex(where: { $0.leaseID == leaseID }) else {
                return nil
            }
            return state.pendingRequests.remove(at: index)
        }
        guard let removed else { return }
        logger.debug(
            "Cancelled queued request before upstream dispatch",
            metadata: [
                "lease_id": .string(leaseID.uuidString),
            ]
        )
        removed.eventLoop.execute {
            removed.failCancelled()
        }
    }

    package func debugSnapshot() -> UpstreamSlotSchedulerDebugSnapshot {
        state.withLockedValue { state in
            UpstreamSlotSchedulerDebugSnapshot(
                queuedRequestCount: state.pendingRequests.count,
                activeLeaseCountByUpstream: state.activeLeaseIDsByUpstream.reduce(into: [:]) { counts, item in
                    counts[item.key] = 1
                }
            )
        }
    }

    package func occupiedUpstreamIndices() -> Set<Int> {
        state.withLockedValue { Set($0.activeLeaseIDsByUpstream.keys) }
    }

    package func reset() {
        let cancelled = state.withLockedValue { state -> [PendingRequest] in
            let pendingRequests = state.pendingRequests
            state.pendingRequests.removeAll()
            state.activeLeaseIDsByUpstream.removeAll()
            return pendingRequests
        }

        for request in cancelled {
            logger.debug(
                "Cancelled queued request during scheduler reset",
                metadata: [
                    "lease_id": .string(request.leaseID.uuidString),
                    "label": .string(request.descriptor.label),
                ]
            )
            request.eventLoop.execute {
                request.failCancelled()
            }
        }
    }

    package func wake() {
        dispatchQueuedRequestsIfPossible()
    }

    private func dispatchQueuedRequestsIfPossible() {
        let starts = state.withLockedValue { state -> [(PendingRequest, Int)] in
            var ready: [(PendingRequest, Int)] = []

            while state.pendingRequests.isEmpty == false {
                let occupied = Set(state.activeLeaseIDsByUpstream.keys)
                var chosenPendingIndex: Int?
                var chosenUpstreamIndex: Int?

                for (pendingIndex, request) in state.pendingRequests.enumerated() {
                    if let preferredUpstreamIndex = request.preferredUpstreamIndex {
                        guard state.activeLeaseIDsByUpstream[preferredUpstreamIndex] == nil else {
                            continue
                        }
                        guard canUseUpstream(preferredUpstreamIndex) else {
                            continue
                        }
                        chosenPendingIndex = pendingIndex
                        chosenUpstreamIndex = preferredUpstreamIndex
                        break
                    }

                    guard let selectedUpstreamIndex = selectUpstream(occupied) else {
                        break
                    }
                    guard state.activeLeaseIDsByUpstream[selectedUpstreamIndex] == nil else {
                        break
                    }
                    chosenPendingIndex = pendingIndex
                    chosenUpstreamIndex = selectedUpstreamIndex
                    break
                }

                guard let chosenPendingIndex, let chosenUpstreamIndex else {
                    break
                }

                let pendingRequest = state.pendingRequests.remove(at: chosenPendingIndex)
                let upstreamIndex = chosenUpstreamIndex
                state.activeLeaseIDsByUpstream[upstreamIndex] = pendingRequest.leaseID
                ready.append((pendingRequest, upstreamIndex))
            }

            return ready
        }

        for (request, upstreamIndex) in starts {
            logger.debug(
                "Dispatching queued request to upstream slot",
                metadata: [
                    "lease_id": .string(request.leaseID.uuidString),
                    "label": .string(request.descriptor.label),
                    "upstream": .string("\(upstreamIndex)"),
                ]
            )
            request.eventLoop.execute {
                request.start(upstreamIndex)
            }
        }
    }
}
