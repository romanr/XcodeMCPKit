import Foundation

private struct InstallOptions {
    var prefix: String?
    var bindir: String?
    var dryRun: Bool
}

private enum InstallError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

private func printUsage() {
    let text = """
    Usage:
      xcode-mcp-proxy-install [--bindir path] [--prefix path] [--dry-run]

    Options:
      --bindir path   Install to this directory (overrides --prefix)
      --prefix path   Install to <prefix>/bin (default: ~/.local)
      --dry-run       Print actions without copying files
      -h, --help      Show this help

    Examples:
      swift run -c release xcode-mcp-proxy-install
      swift run -c release xcode-mcp-proxy-install --bindir "$HOME/bin"
    """
    print(text)
}

private func expandPath(_ path: String) -> String {
    if path.hasPrefix("~") {
        return (path as NSString).expandingTildeInPath
    }
    return path
}

private func parseOptions(_ args: [String], environment: [String: String]) throws -> InstallOptions {
    var options = InstallOptions(prefix: nil, bindir: nil, dryRun: false)
    options.prefix = environment["PREFIX"]
    options.bindir = environment["BINDIR"]

    var index = 1
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--prefix":
            guard index + 1 < args.count else {
                throw InstallError.message("--prefix requires a value")
            }
            options.prefix = args[index + 1]
            index += 2
        case "--bindir":
            guard index + 1 < args.count else {
                throw InstallError.message("--bindir requires a value")
            }
            options.bindir = args[index + 1]
            index += 2
        case "--dry-run":
            options.dryRun = true
            index += 1
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            throw InstallError.message("unknown option: \(arg)")
        }
    }
    return options
}

private func resolveBinDir(prefix: String?, bindir: String?) -> URL {
    if let bindir {
        return URL(fileURLWithPath: expandPath(bindir), isDirectory: true)
    }
    let defaultPrefix = prefix ?? "\(NSHomeDirectory())/.local"
    let expandedPrefix = expandPath(defaultPrefix)
    return URL(fileURLWithPath: expandedPrefix, isDirectory: true).appendingPathComponent("bin", isDirectory: true)
}

private func logError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}

private func install(options: InstallOptions) throws {
    guard let selfURL = Bundle.main.executableURL else {
        throw InstallError.message("failed to locate installer executable")
    }
    let baseURL = selfURL.deletingLastPathComponent()
    let fileManager = FileManager.default

    let binDir = resolveBinDir(prefix: options.prefix, bindir: options.bindir)
    let binaries = ["xcode-mcp-proxy", "xcode-mcp-proxy-server"]

    if options.dryRun {
        print("Would create: \(binDir.path)")
        for name in binaries {
            print("Would install: \(binDir.appendingPathComponent(name).path)")
        }
        return
    }

    try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
    let missing = binaries.filter { name in
        !fileManager.fileExists(atPath: baseURL.appendingPathComponent(name).path)
    }
    if !missing.isEmpty {
        let repoRoot = repositoryRoot(from: selfURL)
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        try buildProducts(missing, in: repoRoot)
    }

    for name in binaries {
        let sourceURL = baseURL.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw InstallError.message("\(name) not found next to installer (run with `swift run -c release` from the repo root)")
        }
        let destinationURL = binDir.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
        print("Installed \(name) to \(destinationURL.path)")
    }
}

private func repositoryRoot(from executableURL: URL) -> URL? {
    var current = executableURL
    while current.path != "/" {
        if current.lastPathComponent == ".build" {
            return current.deletingLastPathComponent()
        }
        current = current.deletingLastPathComponent()
    }
    return nil
}

private func buildProducts(_ products: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    var arguments = ["swift", "build", "-c", "release"]
    for product in products {
        arguments += ["--product", product]
    }
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw InstallError.message("swift build failed; run from the repo root and try again")
    }
}

do {
    let options = try parseOptions(CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    try install(options: options)
} catch let error as InstallError {
    logError("error: \(error.description)")
    logError("run with --help for usage")
    exit(1)
} catch {
    logError("error: \(error)")
    exit(1)
}
