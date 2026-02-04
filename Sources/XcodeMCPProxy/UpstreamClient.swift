import Foundation

enum UpstreamEvent: Sendable {
    case message(Data)
    case exit(Int32)
}

protocol UpstreamClient: Sendable {
    var events: AsyncStream<UpstreamEvent> { get }
    func start() async
    func stop() async
    func send(_ data: Data) async
}
