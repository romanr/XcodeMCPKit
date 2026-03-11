import Foundation
import Testing

@testable import ProxyCore

@Suite
struct JSONValueTests {
    @Test func rpcIdFromString() async throws {
        let rpcId = RPCId(any: "abc")
        #expect(rpcId?.key == "abc")
        #expect(rpcId?.value.foundationObject as? String == "abc")
    }

    @Test func rpcIdFromNumber() async throws {
        let rpcId = RPCId(any: NSNumber(value: 42))
        #expect(rpcId?.key == "42")
        #expect((rpcId?.value.foundationObject as? NSNumber)?.intValue == 42)
    }

    @Test func jsonValueRoundTrip() async throws {
        let input: [String: Any] = [
            "name": "x",
            "count": 2,
            "ok": true,
            "items": [1, 2],
        ]
        let jsonValue = JSONValue(any: input)
        #expect(jsonValue != nil)
        guard let jsonValue else { return }
        let object = jsonValue.foundationObject as? [String: Any]
        #expect(object?["name"] as? String == "x")
        #expect((object?["count"] as? NSNumber)?.intValue == 2)
        #expect(object?["ok"] as? Bool == true)
        #expect((object?["items"] as? [Any])?.count == 2)
    }
}
