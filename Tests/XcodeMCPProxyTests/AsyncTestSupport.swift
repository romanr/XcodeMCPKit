import Foundation
import NIO
import Testing

struct AsyncTestTimeoutError: Error, CustomStringConvertible {
    let description: String
}

actor RecordedValues<Value: Sendable> {
    private struct Waiter {
        let id: UUID
        let index: Int
        let continuation: CheckedContinuation<Value, Error>
    }

    private var values: [Value] = []
    private var waiters: [Waiter] = []

    func append(_ value: Value) {
        let index = values.count
        values.append(value)

        var remaining: [Waiter] = []
        for waiter in waiters {
            if waiter.index == index {
                waiter.continuation.resume(returning: value)
            } else if values.indices.contains(waiter.index) {
                let existing = values[waiter.index]
                waiter.continuation.resume(returning: existing)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    func snapshot() -> [Value] {
        values
    }

    func count() -> Int {
        values.count
    }

    func value(at index: Int) -> Value? {
        guard values.indices.contains(index) else {
            return nil
        }
        return values[index]
    }

    func nextValue(at index: Int) async throws -> Value {
        if let existing = value(at: index) {
            return existing
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: waiterID, index: index, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

@discardableResult
func waitWithTimeout<T: Sendable>(
    _ description: String = "timed out waiting for async operation",
    timeout: Duration = .seconds(5),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let clock = ContinuousClock()

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(until: clock.now.advanced(by: timeout))
            throw AsyncTestTimeoutError(description: description)
        }

        guard let result = try await group.next() else {
            throw AsyncTestTimeoutError(description: description)
        }

        group.cancelAll()
        return result
    }
}

func waitUntil(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while clock.now < deadline {
        if Task.isCancelled {
            return false
        }
        if await condition() {
            return true
        }
        try? await clock.sleep(until: clock.now.advanced(by: pollInterval))
    }

    return await condition()
}

func waitUntilCount(
    _ expectedCount: Int,
    count: @escaping @Sendable () async -> Int,
    timeout: Duration = .seconds(5)
) async -> Bool {
    await waitUntil(timeout: timeout) {
        await count() >= expectedCount
    }
}

func nextValue<Value: Sendable>(
    _ description: String,
    timeout: Duration = .seconds(5),
    value: @escaping @Sendable () async throws -> Value?
) async throws -> Value {
    try await waitWithTimeout(description, timeout: timeout) {
        while true {
            try Task.checkCancellation()
            if let next = try await value() {
                return next
            }
            await Task.yield()
        }
    }
}

func staysTrue(
    for duration: Duration,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)

    while clock.now < deadline {
        if Task.isCancelled {
            return false
        }
        guard await condition() else {
            return false
        }
        await Task.yield()
    }

    return await condition()
}

func shutdown(_ group: EventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}

func shutdownAndWait(_ group: EventLoopGroup) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        await shutdown(group)
        semaphore.signal()
    }
    semaphore.wait()
}
