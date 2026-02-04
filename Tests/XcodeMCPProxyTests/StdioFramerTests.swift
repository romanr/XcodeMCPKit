import Foundation
import Testing
@testable import XcodeMCPProxy

@Test func stdioFramerContentLength() async throws {
    let framer = StdioFramer()
    let json = "{\"jsonrpc\":\"2.0\",\"id\":1}"
    let payload = "Content-Length: \(json.utf8.count)\r\n\r\n\(json)"
    let parts = framer.append(Data(payload.utf8))
    #expect(parts.count == 1)
    #expect(String(data: parts[0], encoding: .utf8) == json)
}

@Test func stdioFramerNDJSON() async throws {
    let framer = StdioFramer()
    let json1 = "{\"jsonrpc\":\"2.0\",\"id\":1}"
    let json2 = "{\"jsonrpc\":\"2.0\",\"id\":2}"
    let payload = "\(json1)\n\(json2)\n"
    let parts = framer.append(Data(payload.utf8))
    #expect(parts.count == 2)
    #expect(String(data: parts[0], encoding: .utf8) == json1)
    #expect(String(data: parts[1], encoding: .utf8) == json2)
}

@Test func stdioFramerRawJSON() async throws {
    let framer = StdioFramer()
    let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}"
    let parts = framer.append(Data(json.utf8))
    #expect(parts.count == 1)
    #expect(String(data: parts[0], encoding: .utf8) == json)
}
