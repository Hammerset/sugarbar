import Foundation

public let mealAnalyzerModel = "claude-sonnet-5-5"

/// Claude's estimate for a photo and/or description: carbs first, with fat, protein, energy and how fast it is
/// likely to absorb. A starting point for the user to review, never saved as-is.
public struct MealEstimate: Equatable, Sendable, Decodable {
    public let carbsGrams: Double
    public let items: [String]
    public let assumptions: [String]
    public let confidence: String
    public let fatGrams: Double?
    public let proteinGrams: Double?
    public let energyKcal: Double?
    public let absorption: AbsorptionSpeed?

    public init(
        carbsGrams: Double,
        items: [String],
        assumptions: [String],
        confidence: String,
        fatGrams: Double? = nil,
        proteinGrams: Double? = nil,
        energyKcal: Double? = nil,
        absorption: AbsorptionSpeed? = nil
    ) {
        self.carbsGrams = carbsGrams
        self.items = items
        self.assumptions = assumptions
        self.confidence = confidence
        self.fatGrams = fatGrams
        self.proteinGrams = proteinGrams
        self.energyKcal = energyKcal
        self.absorption = absorption
    }

    public var summary: String { items.joined(separator: ", ") }

    private enum CodingKeys: String, CodingKey {
        case carbsGrams, items, assumptions, confidence, fatGrams, proteinGrams, energyKcal, absorption
    }

    /// Carbs are required; anything else missing or malformed is dropped rather than failing the Estimate.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        carbsGrams = try container.decode(Double.self, forKey: .carbsGrams)
        items = try container.decode([String].self, forKey: .items)
        assumptions = (try? container.decodeIfPresent([String].self, forKey: .assumptions)) ?? []
        confidence = (try? container.decodeIfPresent(String.self, forKey: .confidence)) ?? "unknown"
        fatGrams = (try? container.decodeIfPresent(Double.self, forKey: .fatGrams)) ?? nil
        proteinGrams = (try? container.decodeIfPresent(Double.self, forKey: .proteinGrams)) ?? nil
        energyKcal = (try? container.decodeIfPresent(Double.self, forKey: .energyKcal)) ?? nil
        let speed = (try? container.decodeIfPresent(String.self, forKey: .absorption)) ?? nil
        absorption = speed.flatMap { AbsorptionSpeed(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
    }
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
        text = "Estimate the carbohydrates, fat, protein and energy in the meal shown in this photo, for insulin dosing by a person with type 1 diabetes.\n" + mealReplyFormat
        if !trimmedNote.isEmpty {
            text += "\n\nThe user added this note about the meal: \(trimmedNote)"
        }
    } else if !trimmedNote.isEmpty {
        text = "Estimate the carbohydrates, fat, protein and energy in the meal the user describes below, for insulin dosing by a person with type 1 diabetes. There is no photo; assume typical portions where the description leaves them open.\n" + mealReplyFormat
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
{"carbsGrams": <number, total grams of carbohydrate>, "fatGrams": <number, total grams of fat>, "proteinGrams": <number, total grams of protein>, "energyKcal": <number, total kilocalories>, "absorption": <"fast" | "medium" | "slow": how quickly the carbs will raise blood glucose, slower with more fat, protein or fibre and for whole foods, faster for sugary drinks, white bread, rice or potatoes eaten alone>, "items": [<short names of the foods, with rough portion sizes>], "assumptions": [<what you had to guess, e.g. hidden sugar, portion size>], "confidence": <"low" | "medium" | "high">}
Carbohydrates matter most: be as accurate as you can there.
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
