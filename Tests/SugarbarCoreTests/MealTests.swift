import Foundation
import Testing

@testable import SugarbarCore

private let estimateJSON = """
{"carbsGrams": 62.5, "items": ["Spaghetti bolognese, large plate", "Garlic bread, 2 slices"], "assumptions": ["Standard pasta portion ~150 g cooked"], "confidence": "medium"}
"""

private func messagesResponse(text: String, stopReason: String = "end_turn") -> String {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return """
    {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5",
     "content": [{"type": "thinking", "thinking": ""}, {"type": "text", "text": "\(escaped)"}],
     "stop_reason": "\(stopReason)", "usage": {"input_tokens": 1500, "output_tokens": 80}}
    """
}

@Suite struct MealEstimateDecodingTests {
    @Test func decodesBareFencedAndWrappedJSON() throws {
        let expected = MealEstimate(
            carbsGrams: 62.5,
            items: ["Spaghetti bolognese, large plate", "Garlic bread, 2 slices"],
            assumptions: ["Standard pasta portion ~150 g cooked"],
            confidence: "medium"
        )
        #expect(try parseMealEstimate(estimateJSON) == expected)
        #expect(try parseMealEstimate("```json\n\(estimateJSON)\n```") == expected)
        #expect(try parseMealEstimate("Here is my estimate:\n\(estimateJSON)\nLet me know if you want more detail.") == expected)
        #expect(expected.summary == "Spaghetti bolognese, large plate, Garlic bread, 2 slices")
    }

    @Test func rejectsTextWithoutAnObject() {
        #expect(throws: MealAnalyzerError.unexpectedResponse) { try parseMealEstimate("I can't see any food here.") }
        #expect(throws: MealAnalyzerError.unexpectedResponse) { try parseMealEstimate(#"{"items": []}"#) }
    }

    @Test func readsTextBlocksAndRefusals() throws {
        let estimate = try decodeMealEstimate(fromMessagesResponse: Data(messagesResponse(text: estimateJSON).utf8))
        #expect(estimate.carbsGrams == 62.5)
        #expect(throws: MealAnalyzerError.declined) {
            try decodeMealEstimate(fromMessagesResponse: Data(messagesResponse(text: "", stopReason: "refusal").utf8))
        }
    }
}

@Suite struct MealAnalyzerFlowTests {
    @Test func postsImageAndNoteWithAPIKeyHeaders() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "api.anthropic.com", path: "/v1/messages", json: messagesResponse(text: estimateJSON))

        let analyzer = MealAnalyzer(transport: transport)
        let estimate = try await analyzer.estimate(imageJPEG: Data([0xFF, 0xD8, 0xFF]), note: "half the bread", apiKey: "sk-test")
        #expect(estimate.confidence == "medium")

        let request = try #require(await transport.lastRequest(host: "api.anthropic.com", path: "/v1/messages"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        let source = try #require(content[0]["source"] as? [String: String])
        #expect(source["media_type"] == "image/jpeg")
        #expect(source["data"] == Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
        let text = try #require(content[1]["text"] as? String)
        #expect(text.contains("carbsGrams"))
        #expect(text.hasSuffix("half the bread"))
    }

    @Test func mapsUnauthorizedToInvalidKey() async {
        let transport = FakeTransport()
        await transport.stub(host: "api.anthropic.com", path: "/v1/messages", status: 401, json: #"{"type":"error"}"#)

        let analyzer = MealAnalyzer(transport: transport)
        await #expect(throws: MealAnalyzerError.invalidAPIKey) {
            try await analyzer.estimate(imageJPEG: Data(), note: "", apiKey: "bad")
        }
    }
}

@Suite struct MealTests {
    @Test func windowsTotalsAndFindsNearbyMeals() {
        let now = Date(timeIntervalSince1970: 1_791_800_000)
        let logged = [
            Meal(timestamp: now.addingTimeInterval(-5 * 3600), carbsGrams: 40, summary: "Breakfast"),
            Meal(timestamp: now.addingTimeInterval(-3 * 3600), carbsGrams: 55, summary: "Lunch"),
            Meal(timestamp: now.addingTimeInterval(-600), carbsGrams: 12.4, summary: "Snack"),
        ]
        let recent = meals(logged, within: .fourHours, of: now)
        #expect(recent.map(\.summary) == ["Lunch", "Snack"])
        #expect(carbTotal(recent) == 67.4)
        #expect(meals(near: now.addingTimeInterval(-500), in: logged, tolerance: 300).map(\.summary) == ["Snack"])
        #expect(meals(near: now.addingTimeInterval(-1000), in: logged, tolerance: 300).isEmpty)
        #expect(formatGrams(12.4) == "12")
    }

    @Test func storeRoundTripsMeals() {
        let suite = "sugarbar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = UserDefaultsMealStore(defaults: defaults)
        #expect(store.load().isEmpty)

        let meal = Meal(timestamp: Date(timeIntervalSince1970: 1_791_800_000), carbsGrams: 40, summary: "Breakfast")
        store.save([meal])
        #expect(store.load() == [meal])
    }
}
