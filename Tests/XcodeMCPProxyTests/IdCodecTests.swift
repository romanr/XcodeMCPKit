import Foundation
import Testing
@testable import XcodeMCPProxy

@Test func idCodecRoundTripString() async throws {
    let sessionId = "session"
    let original = "abc"
    let encoded = IdCodec.encode(sessionId: sessionId, originalId: original)
    let decoded = IdCodec.decode(encoded)
    #expect(decoded?.sessionId == sessionId)
    #expect(decoded?.originalId as? String == original)
}

@Test func idCodecRoundTripNumber() async throws {
    let sessionId = "session"
    let original: NSNumber = 42
    let encoded = IdCodec.encode(sessionId: sessionId, originalId: original)
    let decoded = IdCodec.decode(encoded)
    #expect(decoded?.sessionId == sessionId)
    #expect(decoded?.originalId as? NSNumber == original)
}
