import Foundation
import NIO
import Testing
import XcodeMCPProxy

@Test func e2eRunSomeTests() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["E2E"] == "1" else { return }

    let xcodePid = environment["MCP_XCODE_PID"].flatMap(Int.init)
    let config = ProxyConfig(
        listenHost: "127.0.0.1",
        listenPort: 0,
        upstreamCommand: "xcrun",
        upstreamArgs: ["mcpbridge"],
        xcodePID: xcodePid,
        upstreamSessionID: nil,
        maxBodyBytes: 1_048_576,
        requestTimeout: 60
    )
    let server = ProxyServer(config: config)
    let channel = try server.start()

    let port = try localPort(from: channel)
    let urlString = "http://127.0.0.1:\(port)/mcp"
    guard let url = URL(string: urlString) else {
        throw E2EError.invalidURL(urlString)
    }

    do {
    let initialize = try await rpcCallWithRetryEnvelope(
        url: url,
        sessionId: nil,
        callId: 1,
        method: "initialize",
        params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [:],
            "clientInfo": [
                "name": "xcode-mcp-proxy-e2e",
                "version": "0.0",
            ],
        ]
    )
    guard let sessionId = initialize.sessionId else {
        throw E2EError.missingSessionId
    }

    try await rpcNotify(
        url: url,
        sessionId: sessionId,
        method: "notifications/initialized"
    )

    let tools = try await rpcCallWithRetry(
        url: url,
        sessionId: sessionId,
        callId: 2,
        method: "tools/list"
    )
    let toolList = findFirstKey("tools", in: tools) as? [[String: Any]] ?? []
    let listWindows = findTool(toolList, suffix: "XcodeListWindows")
    let getTestList = findTool(toolList, suffix: "GetTestList")
    let runSomeTests = findTool(toolList, suffix: "RunSomeTests")
    #expect(listWindows != nil)
    #expect(getTestList != nil)
    #expect(runSomeTests != nil)

    guard let listWindows, let getTestList, let runSomeTests else {
        throw E2EError.missingTools
    }

    let windows = try await rpcCallWithRetry(
        url: url,
        sessionId: sessionId,
        callId: 3,
        method: "tools/call",
        params: [
            "name": listWindows,
            "arguments": [:],
        ]
    )
    let envTabIdentifier = environment["MCP_XCODE_TAB_IDENTIFIER"]
    let tabIdentifier = (findFirstKey("tabIdentifier", in: windows) as? String) ?? envTabIdentifier
    guard let tabIdentifier else {
        throw E2EError.missingTabIdentifier
    }

    let testList = try await rpcCallWithRetry(
        url: url,
        sessionId: sessionId,
        callId: 4,
        method: "tools/call",
        params: [
            "name": getTestList,
            "arguments": [
                "tabIdentifier": tabIdentifier,
            ],
        ]
    )

    guard findFirstKey("tests", in: testList) != nil || findFirstKey("testTargets", in: testList) != nil else {
        throw E2EError.missingTests
    }

    guard let test = findTest(in: testList) else {
        throw E2EError.missingTests
    }

    let runResult = try await rpcCallWithRetry(
        url: url,
        sessionId: sessionId,
        callId: 5,
        method: "tools/call",
        params: [
            "name": runSomeTests,
            "arguments": [
                "tabIdentifier": tabIdentifier,
                "tests": [
                    [
                        "targetName": test.targetName,
                        "testIdentifier": test.identifier,
                    ],
                ],
            ],
        ]
    )

    guard findFirstKey("counts", in: runResult) != nil || findFirstKey("results", in: runResult) != nil else {
        throw E2EError.missingRunResults
    }
        _ = try? await server.shutdownGracefully().get()
    } catch {
        _ = try? await server.shutdownGracefully().get()
        throw error
    }
}

private struct RPCResponse {
    let body: [String: Any]
    let sessionId: String?

    var result: [String: Any]? {
        body["result"] as? [String: Any]
    }
}

private func rpcCall(
    url: URL,
    sessionId: String?,
    callId: Int,
    method: String,
    params: [String: Any]? = nil
) async throws -> RPCResponse {
    var payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": callId,
        "method": method,
    ]
    if let params {
        payload["params"] = params
    }

    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let sessionId {
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
    }

    let (responseData, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw E2EError.invalidResponse
    }
    let sessionHeader = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id")
    let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    let object = try decodeResponseBody(data: responseData, contentType: contentType)
    guard let dictionary = object as? [String: Any] else {
        throw E2EError.invalidResponse
    }
    if dictionary["error"] != nil {
        throw E2EError.rpcError
    }
    return RPCResponse(body: dictionary, sessionId: sessionHeader)
}

private func rpcCallWithRetry(
    url: URL,
    sessionId: String?,
    callId: Int,
    method: String,
    params: [String: Any]? = nil,
    attempts: Int = 10,
    delayMilliseconds: UInt64 = 500
) async throws -> [String: Any] {
    var lastError: Error?
    for _ in 0..<attempts {
        do {
            let response = try await rpcCall(
                url: url,
                sessionId: sessionId,
                callId: callId,
                method: method,
                params: params
            )
            if let result = response.result {
                return result
            }
            return response.body
        } catch {
            lastError = error
            try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
        }
    }
    throw lastError ?? E2EError.invalidResponse
}

private func rpcCallWithRetryEnvelope(
    url: URL,
    sessionId: String?,
    callId: Int,
    method: String,
    params: [String: Any]? = nil,
    attempts: Int = 10,
    delayMilliseconds: UInt64 = 500
) async throws -> RPCResponse {
    var lastError: Error?
    for _ in 0..<attempts {
        do {
            return try await rpcCall(
                url: url,
                sessionId: sessionId,
                callId: callId,
                method: method,
                params: params
            )
        } catch {
            lastError = error
            try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
        }
    }
    throw lastError ?? E2EError.invalidResponse
}

private func rpcNotify(
    url: URL,
    sessionId: String,
    method: String
) async throws {
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "method": method,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw E2EError.invalidResponse
    }
    guard httpResponse.statusCode == 202 || httpResponse.statusCode == 204 else {
        throw E2EError.invalidResponse
    }
}

private func localPort(from channel: Channel) throws -> Int {
    guard let address = channel.localAddress else {
        throw E2EError.invalidResponse
    }
    guard let port = address.port else {
        throw E2EError.invalidResponse
    }
    return Int(port)
}

private func findTool(_ tools: [[String: Any]], suffix: String) -> String? {
    for tool in tools {
        guard let name = tool["name"] as? String else { continue }
        if name == suffix || name.hasSuffix(suffix) {
            return name
        }
    }
    return nil
}

private func findFirstKey(_ key: String, in object: Any) -> Any? {
    if let dictionary = object as? [String: Any] {
        if let value = dictionary[key] {
            return value
        }
        for value in dictionary.values {
            if let found = findFirstKey(key, in: value) {
                return found
            }
        }
    } else if let array = object as? [Any] {
        for item in array {
            if let found = findFirstKey(key, in: item) {
                return found
            }
        }
    }
    return nil
}

private func findTest(in object: Any) -> (targetName: String, identifier: String)? {
    if let dictionary = object as? [String: Any] {
        if let targetName = dictionary["targetName"] as? String,
           let identifier = dictionary["identifier"] as? String {
            return (targetName, identifier)
        }
        for value in dictionary.values {
            if let found = findTest(in: value) {
                return found
            }
        }
    } else if let array = object as? [Any] {
        for item in array {
            if let found = findTest(in: item) {
                return found
            }
        }
    }
    return nil
}

private func decodeResponseBody(data: Data, contentType: String) throws -> Any {
    if contentType.hasPrefix("text/event-stream") {
        let text = String(decoding: data, as: UTF8.self)
        guard let payload = extractSsePayload(from: text) else {
            throw E2EError.invalidResponse
        }
        return try JSONSerialization.jsonObject(with: Data(payload.utf8), options: [])
    }
    return try JSONSerialization.jsonObject(with: data, options: [])
}

private func extractSsePayload(from text: String) -> String? {
    let events = text.components(separatedBy: "\n\n")
    for event in events {
        let lines = event.split(separator: "\n", omittingEmptySubsequences: false)
        var dataLines: [String] = []
        for line in lines {
            if line.hasPrefix("data:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                dataLines.append(value)
            }
        }
        if !dataLines.isEmpty {
            return dataLines.joined(separator: "\n")
        }
    }
    return nil
}

enum E2EError: Error {
    case invalidURL(String)
    case invalidResponse
    case rpcError
    case missingTools
    case missingTabIdentifier
    case missingTests
    case missingRunResults
    case missingSessionId
}
