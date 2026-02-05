import Foundation
import Dispatch

private enum BenchMode: String {
    case list = "list"
    case call = "call"
}

private struct Options {
    var url: URL = URL(string: "http://localhost:8765/mcp")!
    var clientName: String = "Codex"
    var mode: BenchMode = .list
    var toolName: String?
    var toolArgsJSON: String = "{}"
    var concurrency: Int = 20
    var requests: Int = 200
    var sessions: Int = 1
    var warmup: Int = 20
    var timeoutSeconds: TimeInterval = 60
    var printTools: Bool = false
    var verbose: Bool = false
}

private enum BenchError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

private func parseOptions(args: [String]) throws -> Options {
    var options = Options()

    var index = 1
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-h", "--help":
            print(usage())
            exit(0)
        case "--url":
            index += 1
            guard index < args.count else { throw BenchError.message("--url requires a value") }
            guard let url = URL(string: args[index]) else { throw BenchError.message("invalid --url: \(args[index])") }
            options.url = url
        case "--client-name":
            index += 1
            guard index < args.count else { throw BenchError.message("--client-name requires a value") }
            options.clientName = args[index]
        case "--mode":
            index += 1
            guard index < args.count else { throw BenchError.message("--mode requires a value") }
            guard let mode = BenchMode(rawValue: args[index]) else {
                throw BenchError.message("invalid --mode: \(args[index]) (expected: list|call)")
            }
            options.mode = mode
        case "--tool":
            index += 1
            guard index < args.count else { throw BenchError.message("--tool requires a value") }
            options.toolName = args[index]
        case "--args":
            index += 1
            guard index < args.count else { throw BenchError.message("--args requires a JSON value") }
            options.toolArgsJSON = args[index]
        case "--args-file":
            index += 1
            guard index < args.count else { throw BenchError.message("--args-file requires a path") }
            let path = args[index]
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            options.toolArgsJSON = String(decoding: data, as: UTF8.self)
        case "--concurrency":
            index += 1
            guard index < args.count else { throw BenchError.message("--concurrency requires a value") }
            options.concurrency = Int(args[index]) ?? options.concurrency
        case "--requests":
            index += 1
            guard index < args.count else { throw BenchError.message("--requests requires a value") }
            options.requests = Int(args[index]) ?? options.requests
        case "--sessions":
            index += 1
            guard index < args.count else { throw BenchError.message("--sessions requires a value") }
            options.sessions = Int(args[index]) ?? options.sessions
        case "--warmup":
            index += 1
            guard index < args.count else { throw BenchError.message("--warmup requires a value") }
            options.warmup = Int(args[index]) ?? options.warmup
        case "--timeout":
            index += 1
            guard index < args.count else { throw BenchError.message("--timeout requires seconds") }
            options.timeoutSeconds = TimeInterval(args[index]) ?? options.timeoutSeconds
        case "--print-tools":
            options.printTools = true
        case "--verbose":
            options.verbose = true
        default:
            throw BenchError.message("unknown argument: \(arg)")
        }
        index += 1
    }

    return options
}

private func validate(options: Options) throws {
    if options.concurrency <= 0 { throw BenchError.message("--concurrency must be > 0") }
    if options.requests <= 0 { throw BenchError.message("--requests must be > 0") }
    if options.sessions <= 0 { throw BenchError.message("--sessions must be > 0") }
    if options.warmup < 0 { throw BenchError.message("--warmup must be >= 0") }
    if options.timeoutSeconds <= 0 { throw BenchError.message("--timeout must be > 0") }
    if options.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw BenchError.message("--client-name must be non-empty")
    }
    if options.mode == .call, options.toolName == nil {
        throw BenchError.message("--tool is required for --mode call")
    }
    if options.mode == .call {
        _ = try parseJSONObject(options.toolArgsJSON, label: "--args/--args-file")
    }
}

private func usage() -> String {
    """
    Usage:
      swift Tools/mcp_bench.swift [options]
      # or (recommended for stable timings):
      swiftc -O Tools/mcp_bench.swift -o /tmp/mcp_bench && /tmp/mcp_bench [options]

    Options:
      --url URL               MCP HTTP endpoint (default: http://localhost:8765/mcp)
      --client-name NAME      MCP clientInfo.name (default: Codex)
      --mode list|call        Benchmark request type (default: list)
      --tool NAME             Tool name for tools/call (required for --mode call)
      --args JSON             Tool arguments JSON object for tools/call (default: {})
      --args-file PATH        Tool arguments JSON object from file
      --concurrency N         In-flight requests (default: 20)
      --requests N            Total measured requests (default: 200)
      --sessions N            Distinct MCP sessions to create (default: 1)
      --warmup N              Warmup requests (not measured) (default: 20)
      --timeout SECONDS       Per-request timeout (default: 60)
      --print-tools           Print tool names (runs a single tools/list)
      --verbose               Print per-request failures
      -h, --help              Show help

    Examples:
      swift Tools/mcp_bench.swift --mode list --requests 200 --concurrency 20
      swift Tools/mcp_bench.swift --print-tools
      swift Tools/mcp_bench.swift --mode call --tool XcodeListWindows --requests 100 --concurrency 10
    """
}

private func run(options: Options) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = options.timeoutSeconds
    configuration.timeoutIntervalForResource = options.timeoutSeconds
    let session = URLSession(configuration: configuration)

    print("target: \(options.url.absoluteString)")
    print("mode: \(options.mode.rawValue)\(options.mode == .call ? " (\(options.toolName!))" : "")")
    print("sessions: \(options.sessions), concurrency: \(options.concurrency), requests: \(options.requests), warmup: \(options.warmup), timeout: \(Int(options.timeoutSeconds))s")
    print("")

    var sessionIds: [String] = []
    sessionIds.reserveCapacity(options.sessions)
    for _ in 0..<options.sessions {
        let id = try await initializeSession(
            http: session,
            url: options.url,
            timeoutSeconds: options.timeoutSeconds,
            clientName: options.clientName
        )
        sessionIds.append(id)
    }

    if options.printTools {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ]
        let response = await sendRPC(
            http: session,
            url: options.url,
            sessionId: sessionIds[0],
            payload: payload,
            timeoutSeconds: options.timeoutSeconds
        )
        if let errorText = response.errorText {
            throw BenchError.message("tools/list failed: \(errorText)")
        }
        try printTools(from: response.body)
        return
    }

    if options.warmup > 0 {
        print("warmup...")
        _ = try await runRequests(
            http: session,
            options: options,
            sessionIds: sessionIds,
            count: options.warmup,
            measure: false
        )
        print("")
    }

    print("run...")
    let results = try await runRequests(
        http: session,
        options: options,
        sessionIds: sessionIds,
        count: options.requests,
        measure: true
    )
    print("")
    printReport(results: results)
}

private struct RPCResponse {
    var httpStatus: Int
    var latencyMs: Double
    var body: [String: Any]
    var errorText: String?
}

private func initializeSession(
    http: URLSession,
    url: URL,
    timeoutSeconds: TimeInterval,
    clientName: String
) async throws -> String {
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-03-26",
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": clientName,
                "version": "0.0",
            ],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.timeoutInterval = timeoutSeconds
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (responseData, response) = try await http.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw BenchError.message("initialize failed: invalid response")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
        let body = String(decoding: responseData, as: UTF8.self)
        throw BenchError.message("initialize failed: HTTP \(httpResponse.statusCode): \(body)")
    }
    guard let sessionId = httpResponse.value(forHTTPHeaderField: "Mcp-Session-Id"), !sessionId.isEmpty else {
        throw BenchError.message("initialize failed: missing Mcp-Session-Id")
    }
    return sessionId
}

private func sendRPC(
    http: URLSession,
    url: URL,
    sessionId: String,
    payload: [String: Any],
    timeoutSeconds: TimeInterval
) async -> RPCResponse {
    let start = DispatchTime.now().uptimeNanoseconds
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: payload, options: [])
    } catch {
        let end = DispatchTime.now().uptimeNanoseconds
        let latencyMs = Double(end - start) / 1_000_000.0
        return RPCResponse(httpStatus: -1, latencyMs: latencyMs, body: [:], errorText: "encode failed: \(error)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.timeoutInterval = timeoutSeconds
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")

    let responseData: Data
    let response: URLResponse
    do {
        (responseData, response) = try await http.data(for: request)
    } catch {
        let end = DispatchTime.now().uptimeNanoseconds
        let latencyMs = Double(end - start) / 1_000_000.0
        let detail: String
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                detail = "timeout"
            case .cannotConnectToHost:
                detail = "cannotConnectToHost"
            case .cannotFindHost:
                detail = "cannotFindHost"
            case .networkConnectionLost:
                detail = "networkConnectionLost"
            default:
                detail = "URLError(\(urlError.code.rawValue))"
            }
        } else {
            detail = String(describing: error)
        }
        return RPCResponse(httpStatus: -1, latencyMs: latencyMs, body: [:], errorText: "transport error: \(detail)")
    }
    let end = DispatchTime.now().uptimeNanoseconds
    let latencyMs = Double(end - start) / 1_000_000.0

    guard let httpResponse = response as? HTTPURLResponse else {
        return RPCResponse(httpStatus: -1, latencyMs: latencyMs, body: [:], errorText: "invalid response")
    }
    let object = (try? JSONSerialization.jsonObject(with: responseData, options: [])) as? [String: Any] ?? [:]

    var errorText: String?
    if !(200...299).contains(httpResponse.statusCode) {
        errorText = "HTTP \(httpResponse.statusCode)"
    } else if object["error"] != nil {
        errorText = "jsonrpc error"
    }
    return RPCResponse(httpStatus: httpResponse.statusCode, latencyMs: latencyMs, body: object, errorText: errorText)
}

private struct BenchResults {
    var wallSeconds: Double
    var okCount: Int
    var errorCount: Int
    var latenciesMs: [Double]
    var errorSamples: [String]
}

private func runRequests(
    http: URLSession,
    options: Options,
    sessionIds: [String],
    count: Int,
    measure: Bool
) async throws -> BenchResults {
    let toolArgs: [String: Any]
    if options.mode == .call {
        toolArgs = try parseJSONObject(options.toolArgsJSON, label: "--args/--args-file")
    } else {
        toolArgs = [:]
    }

    let startWall = DispatchTime.now().uptimeNanoseconds
    let concurrency = min(options.concurrency, count)
    var nextId = 1000

    return await withTaskGroup(of: RPCResponse.self) { group in
        var submitted = 0

        func makePayload(id: Int, sessionIndex: Int) -> (String, [String: Any]) {
            let sessionId = sessionIds[sessionIndex % sessionIds.count]
            switch options.mode {
            case .list:
                let payload: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": "tools/list",
                ]
                return (sessionId, payload)
            case .call:
                let payload: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": "tools/call",
                    "params": [
                        "name": options.toolName ?? "",
                        "arguments": toolArgs,
                    ],
                ]
                return (sessionId, payload)
            }
        }

        for i in 0..<concurrency {
            let id = nextId
            nextId += 1
            let (sessionId, payload) = makePayload(id: id, sessionIndex: i)
            group.addTask {
                await sendRPC(http: http, url: options.url, sessionId: sessionId, payload: payload, timeoutSeconds: options.timeoutSeconds)
            }
            submitted += 1
        }

        var okCount = 0
        var errorCount = 0
        var latenciesMs: [Double] = []
        latenciesMs.reserveCapacity(count)
        var errorSamples: [String] = []
        errorSamples.reserveCapacity(10)

        while let response = await group.next() {
            if let errorText = response.errorText {
                errorCount += 1
                if options.verbose {
                    let idValue = (response.body["id"] as? NSNumber).map { String($0.intValue) } ?? "-"
                    let method = options.mode == .list ? "tools/list" : "tools/call"
                    let latency = String(format: "%.1f", response.latencyMs)
                    FileHandle.standardError.write(Data("fail \(method) id=\(idValue) status=\(response.httpStatus) latency=\(latency)ms (\(errorText))\n".utf8))
                }
                if errorSamples.count < 10 {
                    errorSamples.append(errorText)
                }
            } else {
                okCount += 1
                if measure {
                    latenciesMs.append(response.latencyMs)
                }
            }

            if submitted < count {
                let id = nextId
                nextId += 1
                let (sessionId, payload) = makePayload(id: id, sessionIndex: submitted)
                group.addTask {
                    await sendRPC(http: http, url: options.url, sessionId: sessionId, payload: payload, timeoutSeconds: options.timeoutSeconds)
                }
                submitted += 1
            }
        }

        let endWall = DispatchTime.now().uptimeNanoseconds
        let wallSeconds = Double(endWall - startWall) / 1_000_000_000.0
        return BenchResults(
            wallSeconds: wallSeconds,
            okCount: okCount,
            errorCount: errorCount,
            latenciesMs: latenciesMs,
            errorSamples: errorSamples
        )
    }
}

private func parseJSONObject(_ text: String, label: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    guard let raw = try? JSONSerialization.jsonObject(with: data, options: []) else {
        throw BenchError.message("\(label) must be a JSON object")
    }
    guard let object = raw as? [String: Any] else {
        throw BenchError.message("\(label) must be a JSON object")
    }
    return object
}

private func printReport(results: BenchResults) {
    let total = results.okCount + results.errorCount
    let rps = results.wallSeconds > 0 ? Double(total) / results.wallSeconds : 0
    print("completed: \(total) (ok=\(results.okCount), err=\(results.errorCount))")
    print(String(format: "wall: %.3fs, throughput: %.1f req/s", results.wallSeconds, rps))

    if results.latenciesMs.isEmpty {
        if results.errorCount > 0 {
            print("latency: no successful samples")
        }
        if !results.errorSamples.isEmpty {
            print("error samples: \(results.errorSamples.joined(separator: ", "))")
        }
        return
    }

    let stats = latencyStats(results.latenciesMs)
    print(String(format: "latency (ms): min=%.1f p50=%.1f p90=%.1f p99=%.1f max=%.1f avg=%.1f", stats.min, stats.p50, stats.p90, stats.p99, stats.max, stats.avg))
    if !results.errorSamples.isEmpty {
        print("error samples: \(results.errorSamples.joined(separator: ", "))")
    }
}

private struct LatencyStats {
    var min: Double
    var p50: Double
    var p90: Double
    var p99: Double
    var max: Double
    var avg: Double
}

private func latencyStats(_ samples: [Double]) -> LatencyStats {
    let sorted = samples.sorted()
    let min = sorted.first ?? 0
    let max = sorted.last ?? 0
    let avg = sorted.reduce(0, +) / Double(sorted.count)
    let p50 = percentile(sorted, 0.50)
    let p90 = percentile(sorted, 0.90)
    let p99 = percentile(sorted, 0.99)
    return LatencyStats(min: min, p50: p50, p90: p90, p99: p99, max: max, avg: avg)
}

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let clamped = min(max(p, 0), 1)
    let index = Int((Double(sorted.count - 1) * clamped).rounded(.toNearestOrEven))
    return sorted[min(max(index, 0), sorted.count - 1)]
}

private func printTools(from response: [String: Any]) throws {
    guard let result = response["result"] as? [String: Any] else {
        throw BenchError.message("tools/list: missing result")
    }
    guard let tools = result["tools"] as? [[String: Any]] else {
        throw BenchError.message("tools/list: missing result.tools")
    }

    for tool in tools {
        guard let name = tool["name"] as? String else { continue }
        let desc = (tool["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let desc, !desc.isEmpty {
            print("\(name) - \(desc)")
        } else {
            print(name)
        }
    }
}

private let options: Options
do {
    options = try parseOptions(args: CommandLine.arguments)
} catch let error as BenchError {
    FileHandle.standardError.write(Data(("error: \(error.description)\n").utf8))
    FileHandle.standardError.write(Data((usage() + "\n").utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}

Task {
    do {
        var runOptions = options
        if runOptions.printTools {
            runOptions.mode = .list
            runOptions.requests = 1
            runOptions.concurrency = 1
            runOptions.warmup = 0
        }
        try validate(options: runOptions)
        try await run(options: runOptions)
        exit(0)
    } catch let error as BenchError {
        FileHandle.standardError.write(Data(("error: \(error.description)\n").utf8))
        FileHandle.standardError.write(Data((usage() + "\n").utf8))
        exit(2)
    } catch {
        FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
        exit(1)
    }
}

dispatchMain()
