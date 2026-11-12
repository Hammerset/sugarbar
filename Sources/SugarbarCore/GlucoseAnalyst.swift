import Foundation

public let analystModel = "claude-opus-5-5"

/// One exchange in an Ask Claude conversation. An answer keeps Claude's content blocks verbatim
/// so the next request can resend them unchanged.
public struct AnalystTurn: Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let text: String
    let contentJSON: Data?

    init(role: Role, text: String, contentJSON: Data? = nil) {
        self.role = role
        self.text = text
        self.contentJSON = contentJSON
    }
}

/// A multi-turn conversation about one History Summary, held in memory for a session.
public actor GlucoseAnalyst {
    public let context: String
    public private(set) var turns: [AnalystTurn] = []
    private let client: ClaudeClient

    public init(context: String, transport: HTTPTransport) {
        self.context = context
        self.client = ClaudeClient(transport: transport)
    }

    /// The question joins the history only once Claude has answered, so a failed send can be retried.
    public func ask(_ question: String, apiKey: String) async throws -> String {
        let pending = turns + [AnalystTurn(role: .user, text: question)]
        let reply = try await client.send(body: analystRequestBody(context: context, turns: pending), apiKey: apiKey, timeout: 300)
        var answer = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty { throw ClaudeAPIError.unexpectedResponse }
        if reply.stopReason == "max_tokens" { answer += "\n\n*(Answer cut short.)*" }
        turns = pending + [AnalystTurn(role: .assistant, text: answer, contentJSON: reply.contentJSON)]
        return answer
    }
}

func analystRequestBody(context: String, turns: [AnalystTurn]) -> [String: Any] {
    let messages: [[String: Any]] = turns.map { turn in
        if turn.role == .assistant,
           let json = turn.contentJSON,
           let blocks = try? JSONSerialization.jsonObject(with: json) {
            return ["role": "assistant", "content": blocks]
        }
        return ["role": turn.role.rawValue, "content": turn.text]
    }
    return [
        "model": analystModel,
        "max_tokens": 16000,
        "output_config": ["effort": "medium"],
        "system": [
            ["type": "text", "text": analystSystemPrompt],
            ["type": "text", "text": context, "cache_control": ["type": "ephemeral"]],
        ],
        "messages": messages,
    ]
}

let analystSystemPrompt = """
You are helping one adult with type 1 diabetes understand their own glucose data. The summary that follows comes from their app: CGM Readings, insulin Doses and logged Meals, with their thresholds and therapy settings.

- Be concrete: refer to specific times and values from the data.
- Point out patterns when the data supports them, such as rises after meals, lows a few hours after a bolus, overnight drift, or times of day that are often high or low.
- You may discuss dose amounts, past or upcoming. Anchor any amount to the app's dose calculation stated in the summary (carbs ÷ carb ratio + correction to target − Insulin on Board, rounded down to the pen step, capped at the maximum single dose) and to the user's own carb ratio and insulin sensitivity, show the arithmetic, and say how uncertain it is: these ratios are working values, carb counts are estimates, and recent pen Doses may be missing. If you would differ from that calculation, say why. The user decides; this app is not a medical device.
- You may point out when the data suggests their carb ratio or insulin sensitivity may be off, and suggest checking that with their diabetes care team rather than changing it on one meal's evidence.
- Planned Meals in the summary have not been eaten yet; never count them as eaten.
- Say when data is missing or uncertain. Pen Doses only appear after the pen is synced over NFC, so recent Doses may be absent unless the user entered them in the app. Meals only appear if they were logged, so a rise without a logged Meal may still be food.
- If something looks urgent (for example a current or repeated severe low), say so plainly and suggest contacting their care team.
- Keep answers short and readable on a phone: a few sentences or a short list, in Markdown, without tables.
"""
