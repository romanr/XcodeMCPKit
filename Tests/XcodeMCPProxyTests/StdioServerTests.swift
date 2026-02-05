import Foundation
import NIO
import Testing
@testable import XcodeMCPProxy

@Test func stdioInitializeResponds() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { Task { await shutdown(group) } }
    let eventLoop = group.next()
    let upstream = TestUpstreamClient()
    let config = ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        xcodePID: nil,
        upstreamSessionID: nil,
        maxBodyBytes: 1024,
        requestTimeout: 5,
        eagerInitialize: false,
        transport: .stdio
    )
    let manager = SessionManager(config: config, eventLoop: eventLoop, upstream: upstream)

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let server = StdioServer(
        sessionManager: manager,
        eventLoop: eventLoop,
        input: inputPipe.fileHandleForReading,
        output: outputPipe.fileHandleForWriting
    )
    await server.start()

    let request = makeInitializeRequest(id: 1)
    let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
    inputPipe.fileHandleForWriting.write(requestData)
    inputPipe.fileHandleForWriting.write(Data([0x0A]))

    try await waitForSentCount(upstream, count: 1, timeoutSeconds: 2)
    let sent = await upstream.sent()
    let upstreamId = try extractUpstreamId(from: sent[0])
    let response = try makeInitializeResponse(id: upstreamId)
    await upstream.yield(.message(response))

    let line = try await readLine(from: outputPipe.fileHandleForReading, timeoutSeconds: 2)
    let json = try JSONSerialization.jsonObject(with: line, options: []) as? [String: Any]
    let id = (json?["id"] as? NSNumber)?.intValue ?? -1
    #expect(id == 1)

    await server.stop()
}

private enum ReadError: Error {
    case timeout
}

private func readLine(from handle: FileHandle, timeoutSeconds: UInt64) async throws -> Data {
    let reader = LineReader(handle: handle)
    return try await reader.readLine(timeoutSeconds: timeoutSeconds)
}

private actor LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine(timeoutSeconds: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            handle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { return }
                Task { await self?.append(data) }
            }
            Task { [weak self] in
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                await self?.timeout()
            }
        }
    }

    private func append(_ data: Data) {
        guard !finished else { return }
        buffer.append(data)
        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: 0..<newlineIndex)
            finish(result: .success(line))
        }
    }

    private func timeout() {
        guard !finished else { return }
        finish(result: .failure(ReadError.timeout))
    }

    private func finish(result: Result<Data, Error>) {
        finished = true
        handle.readabilityHandler = nil
        switch result {
        case .success(let line):
            continuation?.resume(returning: line)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}

private func makeInitializeRequest(id: Int) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": "stdio-server-tests",
                "version": "0.0",
            ],
        ],
    ]
}

private func makeInitializeResponse(id: Int64) throws -> Data {
    let response: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id,
        "result": [
            "capabilities": [String: Any](),
        ],
    ]
    return try JSONSerialization.data(withJSONObject: response, options: [])
}

private func extractUpstreamId(from data: Data) throws -> Int64 {
    let object = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    return (object?["id"] as? NSNumber)?.int64Value ?? 0
}

private func shutdown(_ group: EventLoopGroup) async {
    await withCheckedContinuation { continuation in
        group.shutdownGracefully { _ in
            continuation.resume()
        }
    }
}

private func waitForSentCount(
    _ upstream: TestUpstreamClient,
    count: Int,
    timeoutSeconds: UInt64
) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        if await upstream.sent().count >= count {
            return
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw ReadError.timeout
}
