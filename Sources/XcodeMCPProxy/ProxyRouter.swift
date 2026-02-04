import Foundation
import NIO
import NIOConcurrencyHelpers

final class ProxyRouter: @unchecked Sendable {
    private struct Pending {
        var promise: EventLoopPromise<ByteBuffer>
        var timeout: Scheduled<Void>
    }

    private let lock = NIOLock()
    private var pendingById: [String: Pending] = [:]
    private var pendingBatches: [Pending] = []
    private var notificationBuffer: [Data] = []
    private let notificationBufferLimit: Int
    private let requestTimeout: TimeAmount
    private let hasActiveSSE: () -> Bool
    private let sendNotification: (Data) -> Void

    init(
        requestTimeout: TimeAmount,
        notificationBufferLimit: Int = 50,
        hasActiveSSE: @escaping () -> Bool,
        sendNotification: @escaping (Data) -> Void
    ) {
        self.requestTimeout = requestTimeout
        self.notificationBufferLimit = notificationBufferLimit
        self.hasActiveSSE = hasActiveSSE
        self.sendNotification = sendNotification
    }

    func registerRequest(idKey: String, on eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        let timeout = eventLoop.scheduleTask(in: requestTimeout) { [weak self] in
            guard let self else { return }
            self.failTimeout(idKey: idKey)
        }
        lock.withLock {
            pendingById[idKey] = Pending(promise: promise, timeout: timeout)
        }
        return promise.futureResult
    }

    func registerBatch(on eventLoop: EventLoop) -> EventLoopFuture<ByteBuffer> {
        let promise = eventLoop.makePromise(of: ByteBuffer.self)
        let timeout = eventLoop.scheduleTask(in: requestTimeout) { [weak self] in
            guard let self else { return }
            self.failBatchTimeout()
        }
        lock.withLock {
            pendingBatches.append(Pending(promise: promise, timeout: timeout))
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
        lock.withLock {
            let drained = notificationBuffer
            notificationBuffer.removeAll()
            return drained
        }
    }

    private func failTimeout(idKey: String) {
        let pending = lock.withLock { pendingById.removeValue(forKey: idKey) }
        pending?.promise.fail(TimeoutError())
    }

    private func failBatchTimeout() {
        let pending = lock.withLock { pendingBatches.isEmpty ? nil : pendingBatches.removeFirst() }
        pending?.promise.fail(TimeoutError())
    }

    private func pop(idKey: String) -> Pending? {
        lock.withLock {
            pendingById.removeValue(forKey: idKey)
        }
    }

    private func popBatch() -> Pending? {
        lock.withLock {
            pendingBatches.isEmpty ? nil : pendingBatches.removeFirst()
        }
    }

    private func complete(pending: Pending, data: Data) {
        pending.timeout.cancel()
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
        lock.withLock {
            notificationBuffer.append(data)
            if notificationBuffer.count > notificationBufferLimit {
                notificationBuffer.removeFirst(notificationBuffer.count - notificationBufferLimit)
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
