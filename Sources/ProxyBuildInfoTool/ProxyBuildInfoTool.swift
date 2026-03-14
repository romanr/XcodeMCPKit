import Foundation
import ProxyBuildInfoSupport

@main
struct ProxyBuildInfoTool {
    static func main() throws {
        let options = try Options.parse(arguments: CommandLine.arguments)
        let outputURL = URL(fileURLWithPath: options.outputPath)
        let source = BuildInfoVersionResolver.generatedSource(version: options.version)

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if let existingSource = try? String(contentsOf: outputURL, encoding: .utf8),
           existingSource == source
        {
            return
        }

        try source.write(to: outputURL, atomically: true, encoding: .utf8)
    }
}

private struct Options {
    let outputPath: String
    let version: String

    static func parse(arguments: [String]) throws -> Self {
        var outputPath: String?
        var version: String?
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                guard index + 1 < arguments.count else {
                    throw ProxyBuildInfoToolError.message("--output requires a value")
                }
                outputPath = arguments[index + 1]
                index += 2
            case "--version":
                guard index + 1 < arguments.count else {
                    throw ProxyBuildInfoToolError.message("--version requires a value")
                }
                version = arguments[index + 1]
                index += 2
            default:
                throw ProxyBuildInfoToolError.message("unknown option: \(arguments[index])")
            }
        }

        guard let outputPath else {
            throw ProxyBuildInfoToolError.message("--output is required")
        }
        guard let version else {
            throw ProxyBuildInfoToolError.message("--version is required")
        }

        return Self(outputPath: outputPath, version: version)
    }
}

private enum ProxyBuildInfoToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}
