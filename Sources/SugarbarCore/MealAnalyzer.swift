import Foundation

public let mealAnalyzerModel = "claude-sonnet-5-5"

/// Claude's carb estimate for a photo. A starting point for the user to review, never saved as-is.
public struct MealEstimate: Equatable, Sendable, Decodable {
    public let carbsGrams: Double
    public let items: [String]
    public let assumptions: [String]
    public let confidence: String

    public init(carbsGrams: Double, items: [String], assumptions: [String], confidence: String) {
        self.carbsGrams = carbsGrams
        self.items = items
        self.assumptions = assumptions
        self.confidence = confidence
    }

    public var summary: String { items.joined(separator: ", ") }
}

public actor MealAnalyzer {
    private let client: ClaudeClient

    public init(transport: HTTPTransport) {
        self.client = ClaudeClient(transport: transport)
    }

    public func estimate(imageJPEG: Data, note: String, apiKey: String) async throws -> MealEstimate {
        let reply = try await client.send(body: mealRequestBody(imageJPEG: imageJPEG, note: note), apiKey: apiKey)
        return try parseMealEstimate(reply.text)
    }
}

func mealRequestBody(imageJPEG: Data, note: String) -> [String: Any] {
    var text = mealPrompt
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedNote.isEmpty {
        text += "\n\nThe user added this note about the meal: \(trimmedNote)"
    }
    return [
        "model": mealAnalyzerModel,
        "max_tokens": 8192,
        "output_config": ["effort": "medium"],
        "messages": [[
            "role": "user",
            "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]],
                ["type": "text", "text": text],
            ],
        ]],
    ]
}

private let mealPrompt = """
Estimate the total carbohydrates in the meal shown in this photo, for insulin dosing by a person with type 1 diabetes.
Reply with only a JSON object, no prose and no code fence, with exactly these keys:
{"carbsGrams": <number, total grams of carbohydrate>, "items": [<short names of the foods you see, with rough portion sizes>], "assumptions": [<what you had to guess, e.g. hidden sugar, portion size>], "confidence": <"low" | "medium" | "high">}
"""

func decodeMealEstimate(fromMessagesResponse body: Data) throws -> MealEstimate {
    try parseMealEstimate(ClaudeReply(messagesResponse: body).text)
}

/// Accepts the JSON object wherever the model put it: bare, fenced, or wrapped in a sentence.
func parseMealEstimate(_ text: String) throws -> MealEstimate {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
        throw ClaudeAPIError.unexpectedResponse
    }
    let json = Data(text[start...end].utf8)
    guard let estimate = try? JSONDecoder().decode(MealEstimate.self, from: json) else {
        throw ClaudeAPIError.unexpectedResponse
    }
    return estimate
}
