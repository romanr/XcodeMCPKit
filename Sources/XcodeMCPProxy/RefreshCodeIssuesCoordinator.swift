import Foundation

actor RefreshCodeIssuesCoordinator {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
    }

    private var busyKeys: Set<String> = []
    private var waitersByKey: [String: [Waiter]] = [:]

    func withPermit<T: Sendable>(
        key: String,
        body: @Sendable (_ queuePosition: Int) async throws -> T
    ) async rethrows -> T {
        let queuePosition = await acquire(key: key)
        do {
            let result = try await body(queuePosition)
            release(key: key)
            return result
        } catch {
            release(key: key)
            throw error
        }
    }

    private func acquire(key: String) async -> Int {
        if busyKeys.contains(key) == false {
            busyKeys.insert(key)
            return 0
        }

        let queuePosition = (waitersByKey[key]?.count ?? 0) + 1
        await withCheckedContinuation { continuation in
            waitersByKey[key, default: []].append(Waiter(continuation: continuation))
        }
        return queuePosition
    }

    private func release(key: String) {
        guard var waiters = waitersByKey[key], waiters.isEmpty == false else {
            busyKeys.remove(key)
            waitersByKey.removeValue(forKey: key)
            return
        }

        let next = waiters.removeFirst()
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
        next.continuation.resume()
    }
}
