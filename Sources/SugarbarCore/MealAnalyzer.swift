import Foundation

public let mealAnalyzerModel = "claude-sonnet-5-5"

/// Claude's carb estimate for a photo and/or description. A starting point for the user to review, never saved as-is.
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

public enum MealEstimateError: Error, Equatable, Sendable {
    case nothingToEstimate
}

public actor MealAnalyzer {
    private let client: ClaudeClient

    public init(transport: HTTPTransport) {
        self.client = ClaudeClient(transport: transport)
    }

    public func estimate(imageJPEG: Data?, note: String, apiKey: String) async throws -> MealEstimate {
        guard let body = mealRequestBody(imageJPEG: imageJPEG, note: note) else {
            throw MealEstimateError.nothingToEstimate
        }
        let reply = try await client.send(body: body, apiKey: apiKey)
        return try parseMealEstimate(reply.text)
    }
}

/// Nil when there is neither a photo nor a description to estimate from.
func mealRequestBody(imageJPEG: Data?, note: String) -> [String: Any]? {
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    var content: [[String: Any]] = []
    var text: String
    if let imageJPEG {
        content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]])
        text = "Estimate the total carbohydrates in the meal shown in this photo, for insulin dosing by a person with type 1 diabetes.\n" + mealReplyFormat
        if !trimmedNote.isEmpty {
            text += "\n\nThe user added this note about the meal: \(trimmedNote)"
        }
    } else if !trimmedNote.isEmpty {
        text = "Estimate the total carbohydrates in the meal the user describes below, for insulin dosing by a person with type 1 diabetes. There is no photo; assume typical portions where the description leaves them open.\n" + mealReplyFormat
        text += "\n\nThe user's description of the meal: \(trimmedNote)"
    } else {
        return nil
    }
    content.append(["type": "text", "text": text])
    return [
        "model": mealAnalyzerModel,
        "max_tokens": 8192,
        "output_config": ["effort": "medium"],
        "messages": [["role": "user", "content": content]],
    ]
}

private let mealReplyFormat = """
Reply with only a JSON object, no prose and no code fence, with exactly these keys:
{"carbsGrams": <number, total grams of carbohydrate>, "items": [<short names of the foods, with rough portion sizes>], "assumptions": [<what you had to guess, e.g. hidden sugar, portion size>], "confidence": <"low" | "medium" | "high">}
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
