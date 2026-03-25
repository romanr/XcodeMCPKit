import Foundation
import ProxyCore

package enum RefreshCodeIssuesToolsListRewriter {
    package static func rewriteResult(
        _ result: JSONValue,
        mode: RefreshCodeIssuesMode,
        hiddenToolNames: Set<String> = []
    ) -> JSONValue {
        guard case .object(var resultObject) = result,
            case .array(let tools) = resultObject["tools"]
        else {
            return result
        }

        let rewrittenTools = tools.compactMap { toolValue -> JSONValue? in
            guard case .object(var toolObject) = toolValue else {
                return toolValue
            }
            guard case .string(let name) = toolObject["name"] else {
                return toolValue
            }
            guard hiddenToolNames.contains(name) == false else {
                return nil
            }
            guard name == RefreshCodeIssuesRequest.toolName else {
                return toolValue
            }
            toolObject["description"] = .string(description(for: mode))
            return .object(toolObject)
        }
        resultObject["tools"] = .array(rewrittenTools)
        return .object(resultObject)
    }

    package static func rewriteResponseDataIfNeeded(
        _ responseData: Data,
        mode: RefreshCodeIssuesMode,
        hiddenToolNames: Set<String> = []
    ) -> Data {
        guard
            let object = try? JSONSerialization.jsonObject(with: responseData, options: [])
                as? [String: Any],
            let result = object["result"],
            let resultValue = JSONValue(any: result)
        else {
            return responseData
        }

        let rewrittenResult = rewriteResult(
            resultValue,
            mode: mode,
            hiddenToolNames: hiddenToolNames
        )
        guard rewrittenResult.foundationObject as? [String: Any] != nil else {
            return responseData
        }

        var rewrittenObject = object
        rewrittenObject["result"] = rewrittenResult.foundationObject
        guard JSONSerialization.isValidJSONObject(rewrittenObject),
            let rewrittenData = try? JSONSerialization.data(withJSONObject: rewrittenObject, options: [])
        else {
            return responseData
        }
        return rewrittenData
    }

    private static func description(for mode: RefreshCodeIssuesMode) -> String {
        switch mode {
        case .proxy:
            return """
            Returns file-scoped diagnostics for a source file. By default, the proxy serves this via Xcode navigator issues to avoid switching Spaces. Use --refresh-code-issues-mode upstream to use Xcode's native live diagnostics path instead.
            """
        case .upstream:
            return """
            Returns file-scoped diagnostics for a source file. This proxy is configured to pass through to Xcode's native live diagnostics path.
            """
        }
    }
}
