import Foundation

enum UpstreamEvent: Sendable {
    case message(Data)
    case stderr(String)
    case stdoutRecovery(StdioFramerRecovery)
    case stdoutBufferSize(Int)
    case exit(Int32)
}

enum UpstreamSendResult: Sendable {
    case accepted
    case overloaded
}

protocol UpstreamClient: Sendable {
    var events: AsyncStream<UpstreamEvent> { get }
    func start() async
    func stop() async
    func send(_ data: Data) async -> UpstreamSendResult
}
