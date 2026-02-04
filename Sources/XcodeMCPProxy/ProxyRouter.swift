import Foundation
import NIO
import NIOConcurrencyHelpers

final class ProxyRouter: Sendable {
    private struct Pending: Sendable {
        var promise: EventLoopPromise<ByteBuffer>
        var timeout: Scheduled<Void>?
    }

    private struct State: Sendable {
        var pendingById: [String: Pending] = [:]
        var pendingBatches: [Pending] = []
        var notificationBuffer: [Data] = []
    }

    private let state = NIOLockedValueBox(State())
    private let notificationBufferLimit: Int
    private let requestTimeout: TimeAmount?
    private let hasActiveSSE: @Sendable () -> Bool
    private let sendNotification: @Sendable (Data) -> Void

    init(
        requestTimeout: TimeAmount?,
        notificationBufferLimit: Int = 50,
        hasActiveSSE: @escaping @Sendable () -> Bool,
        sendNotification: @escaping @Sendable (Data) -> Void
    ) {
        self.requestTimeout = requestTimeout
        self.notificationBufferLimit = notificationBufferLimit
        self.hasActiveSSE = hasActiveSSE
        self.sendNotification = sendNotification
    }

    func registerRequest(idKey: String, on eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        let timeout = requestTimeout.map { timeout in
            eventLoop.scheduleTask(in: timeout) { [weak self] in
                guard let self else { return }
                self.failTimeout(idKey: idKey)
            }
        }
        state.withLockedValue { state in
            state.pendingById[idKey] = Pending(promise: promise, timeout: timeout)
        }
        return promise.futureResult
    }

    func registerBatch(on eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        let timeout = requestTimeout.map { timeout in
            eventLoop.scheduleTask(in: timeout) { [weak self] in
                guard let self else { return }
                self.failBatchTimeout()
            }
        }
        state.withLockedValue { state in
            state.pendingBatches.append(Pending(promise: promise, timeout: timeout))
        }
        return promise.futureResult
    }

    func handleIncoming(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            notify(data)
            return
        }

        if (json as? [Any]) != nil {
            if let pending = popBatch() {
                complete(pending: pending, data: data)
            } else {
                notify(data)
            }
            return
        }

        if let object = json as? [String: Any] {
            if let idKey = Self.idKey(from: object), let pending = pop(idKey: idKey) {
                complete(pending: pending, data: data)
            } else {
                notify(data)
            }
            return
        }

        notify(data)
    }

    func drainBufferedNotifications() -> [Data] {
        state.withLockedValue { state in
            let drained = state.notificationBuffer
            state.notificationBuffer.removeAll()
            return drained
        }
    }

    private func failTimeout(idKey: String) {
        let pending = state.withLockedValue { state in
            state.pendingById.removeValue(forKey: idKey)
        }
        pending?.promise.fail(TimeoutError())
    }

    private func failBatchTimeout() {
        let pending = state.withLockedValue { state in
            state.pendingBatches.isEmpty ? nil : state.pendingBatches.removeFirst()
        }
        pending?.promise.fail(TimeoutError())
    }

    private func pop(idKey: String) -> Pending? {
        state.withLockedValue { state in
            state.pendingById.removeValue(forKey: idKey)
        }
    }

    private func popBatch() -> Pending? {
        state.withLockedValue { state in
            state.pendingBatches.isEmpty ? nil : state.pendingBatches.removeFirst()
        }
    }

    private func complete(pending: Pending, data: Data) {
        pending.timeout?.cancel()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        pending.promise.succeed(buffer)
    }

    private func notify(_ data: Data) {
        if hasActiveSSE() {
            sendNotification(data)
        } else {
            bufferNotification(data)
        }
    }

    private func bufferNotification(_ data: Data) {
        state.withLockedValue { state in
            state.notificationBuffer.append(data)
            if state.notificationBuffer.count > notificationBufferLimit {
                state.notificationBuffer.removeFirst(state.notificationBuffer.count - notificationBufferLimit)
            }
        }
    }

    private static func idKey(from object: [String: Any]) -> String? {
        guard let id = object["id"], !(id is NSNull) else { return nil }
        if let stringId = id as? String {
            return stringId
        }
        if let numberId = id as? NSNumber {
            return numberId.stringValue
        }
        return String(describing: id)
    }
}

struct TimeoutError: Error {}
