import Foundation
import NIOConcurrencyHelpers

private final class PipeCollector: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let drainGroup: DispatchGroup
    private let buffer = NIOLockedValueBox(Data())

    init(fileHandle: FileHandle, drainGroup: DispatchGroup) {
        self.fileHandle = fileHandle
        self.drainGroup = drainGroup
        self.drainGroup.enter()
    }

    func start() {
        fileHandle.readabilityHandler = { [buffer, drainGroup] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                drainGroup.leave()
                return
            }
            buffer.withLockedValue { data in
                data.append(chunk)
            }
        }
    }

    func collectedData() -> Data {
        buffer.withLockedValue { $0 }
    }

    func cancel() {
        fileHandle.readabilityHandler = nil
        try? fileHandle.close()
        drainGroup.leave()
    }
}

struct ProcessRequest: Sendable {
    let label: String
    let executablePath: String
    let arguments: [String]
    let input: String?
}

struct ProcessOutput: Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessOutput
}

struct ProcessRunner: ProcessRunning {
    func run(_ request: ProcessRequest) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = Pipe()
            let drainGroup = DispatchGroup()
            let stdoutCollector = PipeCollector(
                fileHandle: stdoutPipe.fileHandleForReading,
                drainGroup: drainGroup
            )
            let stderrCollector = PipeCollector(
                fileHandle: stderrPipe.fileHandleForReading,
                drainGroup: drainGroup
            )
            let didResume = NIOLockedValueBox(false)
            let resumeOnce: @Sendable (Result<ProcessOutput, Error>) -> Void = { result in
                let shouldResume = didResume.withLockedValue { didResume in
                    guard didResume == false else { return false }
                    didResume = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            process.executableURL = URL(fileURLWithPath: request.executablePath)
            process.arguments = request.arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            if request.input != nil {
                process.standardInput = stdinPipe
            }
            stdoutCollector.start()
            stderrCollector.start()

            process.terminationHandler = { process in
                DispatchQueue.global().async {
                    drainGroup.wait()
                    let output = ProcessOutput(
                        terminationStatus: process.terminationStatus,
                        stdout: String(decoding: stdoutCollector.collectedData(), as: UTF8.self),
                        stderr: String(decoding: stderrCollector.collectedData(), as: UTF8.self)
                    )
                    resumeOnce(.success(output))
                }
            }

            do {
                try process.run()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                if let input = request.input {
                    if let inputData = input.data(using: .utf8) {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
                    }
                    try stdinPipe.fileHandleForWriting.close()
                }
            } catch {
                process.terminationHandler = nil
                if process.isRunning {
                    process.terminate()
                }
                stdoutCollector.cancel()
                stderrCollector.cancel()
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                try? stdinPipe.fileHandleForWriting.close()
                resumeOnce(.failure(error))
            }
        }
    }
}
