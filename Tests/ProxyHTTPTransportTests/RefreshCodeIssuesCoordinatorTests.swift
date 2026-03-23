import Testing
import XcodeMCPTestSupport

@testable import ProxyFeatureXcode

@Suite(.serialized)
struct RefreshCodeIssuesCoordinatorTests {
    @Test func refreshCoordinatorSerializesRequestsForSameKey() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(
            queueWaitTimeout: .seconds(5),
            queueWaitClock: clock
        )
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-same") { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-same") { _ in
                await acquisitions.append("second")
            }
        }

        await clock.sleep(untilSuspendedBy: 1)
        #expect(await acquisitions.snapshot() == ["first"])
        await releaseFirst.signal()

        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await acquisitions.snapshot() == ["first", "second"])
    }

    @Test func refreshCoordinatorAllowsDifferentKeysToAcquireConcurrently() async throws {
        let coordinator = RefreshCodeIssuesCoordinator()
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-a") { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-b") { _ in
                await acquisitions.append("second")
            }
        }

        try await spinUntil("waiting for second acquisition") {
            await acquisitions.count() == 2
        }

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await acquisitions.snapshot() == ["first", "second"])
    }

    @Test func refreshCoordinatorRejectsWhenPerKeyQueueLimitIsExceeded() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 1,
            maxPendingTotal: 8,
            queueWaitTimeout: .seconds(5),
            queueWaitClock: clock
        )
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-same") { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let secondTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-same") { _ in
                await acquisitions.append("second")
            }
        }

        await clock.sleep(untilSuspendedBy: 1)

        do {
            _ = try await coordinator.withPermit(key: "windowtab-same") { _ in () }
            #expect(Bool(false))
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueLimitExceeded {
            #expect(Bool(true))
        }

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await acquisitions.snapshot() == ["first", "second"])
    }

    @Test func refreshCoordinatorRejectsWhenGlobalQueueLimitIsExceeded() async throws {
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 4,
            maxPendingTotal: 0
        )
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-a") { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        do {
            _ = try await coordinator.withPermit(key: "windowtab-a") { _ in () }
            #expect(Bool(false))
        } catch RefreshCodeIssuesCoordinator.AcquireError.queueLimitExceeded {
            #expect(Bool(true))
        }

        await releaseFirst.signal()
        _ = await firstTask.value
    }

    @Test func refreshCoordinatorTimeoutRemovesQueuedWaiterDeterministically() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 1,
            maxPendingTotal: 4,
            queueWaitTimeout: .milliseconds(50),
            queueWaitClock: clock
        )
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()
        let outcomes = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-timeout") { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let secondTask = Task<Void, Never> {
            do {
                _ = try await coordinator.withPermit(key: "windowtab-timeout") { _ in () }
                await outcomes.append("success")
            } catch RefreshCodeIssuesCoordinator.AcquireError.queueWaitTimedOut {
                await outcomes.append("timed-out")
            } catch {
                await outcomes.append("unexpected")
            }
        }

        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .milliseconds(50))
        try await spinUntil("waiting for timed-out waiter to finish") {
            await outcomes.count() == 1
        }
        #expect(await outcomes.snapshot() == ["timed-out"])

        let thirdTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-timeout") { _ in
                await acquisitions.append("third")
            }
        }

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await secondTask.value
        _ = await thirdTask.value
        #expect(await acquisitions.snapshot() == ["first", "third"])
    }

    @Test func refreshCoordinatorCancellationRemovesQueuedWaiterDeterministically() async throws {
        let clock = TestClock()
        let coordinator = RefreshCodeIssuesCoordinator(
            maxPendingPerKey: 1,
            maxPendingTotal: 4,
            queueWaitTimeout: .seconds(5),
            queueWaitClock: clock
        )
        let releaseFirst = AsyncGate()
        let acquisitions = RecordedValues<String>()
        let outcomes = RecordedValues<String>()

        let firstTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-cancel") { _ in
                await acquisitions.append("first")
                await releaseFirst.wait()
            }
        }
        try await spinUntil("waiting for first acquisition") {
            await acquisitions.count() == 1
        }

        let cancelledTask = Task<Void, Never> {
            do {
                _ = try await coordinator.withPermit(key: "windowtab-cancel") { _ in () }
                await outcomes.append("success")
            } catch is CancellationError {
                await outcomes.append("cancelled")
            } catch {
                await outcomes.append("unexpected")
            }
        }

        await clock.sleep(untilSuspendedBy: 1)
        cancelledTask.cancel()
        try await spinUntil("waiting for cancelled waiter to finish") {
            await outcomes.count() == 1
        }
        #expect(await outcomes.snapshot() == ["cancelled"])

        let thirdTask = Task<Void, Never> {
            _ = try? await coordinator.withPermit(key: "windowtab-cancel") { _ in
                await acquisitions.append("third")
            }
        }

        await releaseFirst.signal()
        _ = await firstTask.value
        _ = await cancelledTask.value
        _ = await thirdTask.value
        #expect(await acquisitions.snapshot() == ["first", "third"])
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard isOpen == false else {
            return
        }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
