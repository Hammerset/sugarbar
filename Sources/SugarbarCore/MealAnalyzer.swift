import Foundation

public let claudeMessagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
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

public enum MealAnalyzerError: Error, Equatable, Sendable {
    case invalidAPIKey
    case rateLimited
    case declined
    case httpError(status: Int)
    case unexpectedResponse
}

public actor MealAnalyzer {
    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    public func estimate(imageJPEG: Data, note: String, apiKey: String) async throws -> MealEstimate {
        var request = URLRequest(url: claudeMessagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: mealRequestBody(imageJPEG: imageJPEG, note: note))

        let response = try await transport.send(request)
        switch response.status {
        case 200...299:
            break
        case 401, 403:
            throw MealAnalyzerError.invalidAPIKey
        case 429:
            throw MealAnalyzerError.rateLimited
        default:
            throw MealAnalyzerError.httpError(status: response.status)
        }
        return try decodeMealEstimate(fromMessagesResponse: response.body)
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
    let message = try JSONDecoder().decode(MessagesResponse.self, from: body)
    if message.stopReason == "refusal" { throw MealAnalyzerError.declined }
    let text = message.content.compactMap(\.text).joined()
    return try parseMealEstimate(text)
}

/// Accepts the JSON object wherever the model put it: bare, fenced, or wrapped in a sentence.
func parseMealEstimate(_ text: String) throws -> MealEstimate {
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
        throw MealAnalyzerError.unexpectedResponse
    }
    let json = Data(text[start...end].utf8)
    guard let estimate = try? JSONDecoder().decode(MealEstimate.self, from: json) else {
        throw MealAnalyzerError.unexpectedResponse
    }
    return estimate
}

private struct MessagesResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }

    let content: [Block]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}
