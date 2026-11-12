import Foundation

public let claudeMessagesURL = URL(string: "https://api.anthropic.com/v1/messages")!

public enum ClaudeAPIError: Error, Equatable, Sendable {
    case invalidAPIKey
    case rateLimited
    case declined
    case httpError(status: Int)
    case unexpectedResponse
}

/// One `POST /v1/messages` with the user's own key; callers build the body and read the reply.
public struct ClaudeClient: Sendable {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public func send(body: [String: Any], apiKey: String, timeout: TimeInterval = 60) async throws -> ClaudeReply {
        var request = URLRequest(url: claudeMessagesURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let response = try await transport.send(request)
        switch response.status {
        case 200...299:
            break
        case 401, 403:
            throw ClaudeAPIError.invalidAPIKey
        case 429:
            throw ClaudeAPIError.rateLimited
        default:
            throw ClaudeAPIError.httpError(status: response.status)
        }
        return try ClaudeReply(messagesResponse: response.body)
    }
}

public struct ClaudeReply: Equatable, Sendable {
    public let text: String
    public let stopReason: String?
    /// The response's content blocks exactly as returned, so a multi-turn conversation can
    /// resend them unchanged (thinking blocks must not be edited or dropped).
    public let contentJSON: Data

    init(messagesResponse body: Data) throws {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let content = object["content"] as? [[String: Any]]
        else { throw ClaudeAPIError.unexpectedResponse }
        let stopReason = object["stop_reason"] as? String
        if stopReason == "refusal" { throw ClaudeAPIError.declined }
        self.stopReason = stopReason
        self.text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        self.contentJSON = try JSONSerialization.data(withJSONObject: content)
    }
}
