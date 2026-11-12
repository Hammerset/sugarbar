import Foundation
import Testing

@testable import SugarbarCore

private let answerResponse = #"""
{"id": "msg_01", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
 "content": [
   {"type": "thinking", "thinking": "", "signature": "sig-abc"},
   {"type": "text", "text": "**Breakfast** at 07:36 (45 g) rose to 9.1 by 09:00."}
 ],
 "stop_reason": "end_turn", "stop_sequence": null,
 "usage": {"input_tokens": 40, "cache_creation_input_tokens": 3100, "cache_read_input_tokens": 0, "output_tokens": 210}}
"""#

private let path = "/v1/messages"
private let host = "api.anthropic.com"

private func body(_ request: URLRequest?) throws -> [String: Any] {
    let data = try #require(request?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite struct GlucoseAnalystTests {
    @Test func firstQuestionSendsCachedContextOnce() async throws {
        let transport = FakeTransport()
        await transport.stub(host: host, path: path, json: answerResponse)
        let analyst = GlucoseAnalyst(context: "# History\n12:00 6.2", transport: transport)

        let answer = try await analyst.ask("Review the last 24 hours", apiKey: "sk-test")
        #expect(answer == "**Breakfast** at 07:36 (45 g) rose to 9.1 by 09:00.")

        let request = try #require(await transport.lastRequest(host: host, path: path))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let sent = try body(request)
        #expect(sent["model"] as? String == "claude-opus-5-5")
        let system = try #require(sent["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect((system[0]["text"] as? String)?.contains("Never give a dosing instruction") == true)
        #expect(system[0]["cache_control"] == nil)
        #expect(system[1]["text"] as? String == "# History\n12:00 6.2")
        #expect((system[1]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        let messages = try #require(sent["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["content"] as? String == "Review the last 24 hours")
    }

    @Test func followUpResendsHistoryWithThinkingBlocksUnchanged() async throws {
        let transport = FakeTransport()
        await transport.stub(host: host, path: path, json: answerResponse)
        let analyst = GlucoseAnalyst(context: "ctx", transport: transport)

        _ = try await analyst.ask("First", apiKey: "k")
        _ = try await analyst.ask("And my nights?", apiKey: "k")

        let messages = try #require(try body(await transport.lastRequest(host: host, path: path))["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let blocks = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["thinking", "text"])
        #expect(blocks[0]["signature"] as? String == "sig-abc")
        #expect(messages[2]["content"] as? String == "And my nights?")
        #expect(await analyst.turns.count == 4)
    }

    @Test func failedQuestionIsNotKeptInHistory() async throws {
        let transport = FakeTransport()
        await transport.stub(host: host, path: path, status: 401, json: #"{"type":"error","error":{"type":"authentication_error"}}"#)
        let analyst = GlucoseAnalyst(context: "ctx", transport: transport)

        await #expect(throws: ClaudeAPIError.invalidAPIKey) { try await analyst.ask("Hi", apiKey: "bad") }
        #expect(await analyst.turns.isEmpty)
    }

    @Test func refusalAndEmptyAnswersAreErrors() {
        let refusal = #"{"content": [], "stop_reason": "refusal"}"#
        #expect(throws: ClaudeAPIError.declined) { try ClaudeReply(messagesResponse: Data(refusal.utf8)) }
        #expect(throws: ClaudeAPIError.unexpectedResponse) { try ClaudeReply(messagesResponse: Data("not json".utf8)) }
    }
}
