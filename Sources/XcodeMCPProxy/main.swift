import Foundation

do {
    let config = try CLIParser.parse(
        args: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    let server = ProxyServer(config: config)
    try server.run()
} catch let error as CLIError {
    print(error.description)
    if !error.description.contains("Usage:") {
        print(CLIParser.usage())
    }
    exit(1)
} catch {
    print("error: \(error)")
    exit(1)
}
