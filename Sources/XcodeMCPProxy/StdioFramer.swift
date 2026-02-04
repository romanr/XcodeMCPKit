import Foundation

final class StdioFramer {
    private var buffer = Data()

    func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var messages: [Data] = []

        while true {
            if let message = nextContentLengthMessage() {
                messages.append(message)
                continue
            }
            let lines = nextNDJSONMessages()
            if lines.isEmpty {
                break
            }
            messages.append(contentsOf: lines)
        }

        return messages
    }

    private func nextContentLengthMessage() -> Data? {
        let headerPrefix = "Content-Length"
        guard buffer.count >= headerPrefix.count else { return nil }
        guard let prefixString = String(data: buffer.prefix(headerPrefix.count), encoding: .utf8),
              prefixString.caseInsensitiveCompare(headerPrefix) == .orderedSame else {
            return nil
        }

        let delimiterCRLF = Data("\r\n\r\n".utf8)
        let delimiterLF = Data("\n\n".utf8)
        let headerEndRange = buffer.range(of: delimiterCRLF) ?? buffer.range(of: delimiterLF)
        guard let headerRange = headerEndRange else { return nil }
        let headerEndIndex = headerRange.upperBound
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var contentLength: Int?
        for line in headerText.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Content-Length") == .orderedSame {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
        }

        guard let length = contentLength, length >= 0 else { return nil }
        guard buffer.count >= headerEndIndex + length else { return nil }

        let bodyRange = headerEndIndex..<(headerEndIndex + length)
        let message = buffer.subdata(in: bodyRange)
        buffer.removeSubrange(0..<(headerEndIndex + length))
        return message
    }

    private func nextNDJSONMessages() -> [Data] {
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return [] }
        let endIndex = buffer.index(after: lastNewline)
        let completeData = buffer.subdata(in: 0..<endIndex)
        buffer.removeSubrange(0..<endIndex)

        var messages: [Data] = []
        var startIndex = completeData.startIndex
        for index in completeData.indices where completeData[index] == 0x0A {
            let lineData = completeData.subdata(in: startIndex..<index)
            startIndex = completeData.index(after: index)
            let trimmed = trimTrailingCR(lineData)
            if trimmed.isEmpty { continue }
            messages.append(trimmed)
        }
        return messages
    }

    private func trimTrailingCR(_ data: Data) -> Data {
        guard let last = data.last, last == 0x0D else { return data }
        return data.dropLast()
    }
}
