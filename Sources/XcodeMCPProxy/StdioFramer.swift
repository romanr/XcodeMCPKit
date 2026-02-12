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
            if let message = nextJSONValueMessage() {
                messages.append(message)
                continue
            }
            if trimLeadingWhitespace() {
                continue
            }
            if dropLeadingNonJSONLine() {
                continue
            }
            break
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

    private func nextJSONValueMessage() -> Data? {
        var index = buffer.startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        if index == buffer.endIndex { return nil }

        let startIndex = index
        let first = buffer[index]
        guard first == 0x7B || first == 0x5B else { return nil }

        var depth = 0
        var inString = false
        var isEscaped = false
        var endIndex: Data.Index?

        while index < buffer.endIndex {
            let byte = buffer[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    depth -= 1
                    if depth == 0 {
                        endIndex = index
                        break
                    }
                }
            }
            index = buffer.index(after: index)
        }

        guard let endIndex, depth == 0, !inString else { return nil }
        let messageEnd = buffer.index(after: endIndex)
        let message = buffer.subdata(in: startIndex..<messageEnd)
        buffer.removeSubrange(0..<messageEnd)
        return message
    }

    private func trimLeadingWhitespace() -> Bool {
        guard !buffer.isEmpty else { return false }
        var index = buffer.startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        if index == buffer.startIndex {
            return false
        }
        if index == buffer.endIndex {
            buffer.removeAll(keepingCapacity: true)
            return true
        }
        buffer.removeSubrange(0..<index)
        return true
    }

    private func dropLeadingNonJSONLine() -> Bool {
        guard !buffer.isEmpty else { return false }

        // If we're at the start of a (possibly partial) Content-Length header, wait for more bytes.
        if isPotentialContentLengthHeaderPrefix() {
            return false
        }

        // If the first non-whitespace token looks like JSON, don't drop anything; we might just be
        // waiting for the rest of a multi-line JSON value.
        if let first = firstNonWhitespaceByte(), first == 0x7B || first == 0x5B {
            return false
        }

        // Drop exactly one line of non-JSON stdout so we don't get stuck on accidental log output.
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { return false }
        let dropEnd = buffer.index(after: newlineIndex)
        buffer.removeSubrange(0..<dropEnd)
        return true
    }

    private func firstNonWhitespaceByte() -> UInt8? {
        var index = buffer.startIndex
        while index < buffer.endIndex, isWhitespace(buffer[index]) {
            index = buffer.index(after: index)
        }
        guard index < buffer.endIndex else { return nil }
        return buffer[index]
    }

    private func isPotentialContentLengthHeaderPrefix() -> Bool {
        let headerPrefix = "Content-Length"
        let count = min(buffer.count, headerPrefix.utf8.count)
        guard count > 0 else { return false }
        guard let prefix = String(data: buffer.prefix(count), encoding: .utf8) else { return false }
        return headerPrefix.lowercased().hasPrefix(prefix.lowercased())
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
