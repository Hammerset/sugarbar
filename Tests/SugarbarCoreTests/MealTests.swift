import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

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
        #expect(throws: ClaudeAPIError.unexpectedResponse) { try parseMealEstimate("I can't see any food here.") }
        #expect(throws: ClaudeAPIError.unexpectedResponse) { try parseMealEstimate(#"{"items": []}"#) }
    }

    @Test func readsTextBlocksAndRefusals() throws {
        let estimate = try decodeMealEstimate(fromMessagesResponse: Data(messagesResponse(text: estimateJSON).utf8))
        #expect(estimate.carbsGrams == 62.5)
        #expect(throws: ClaudeAPIError.declined) {
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

    @Test func estimatesFromADescriptionAloneAndNeedsOneOfTheTwo() async throws {
        let body = try #require(mealRequestBody(imageJPEG: nil, note: "  two slices of toast with jam \n"))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        let text = try #require(content[0]["text"] as? String)
        #expect(!text.contains("this photo"))
        #expect(text.contains("carbsGrams"))
        #expect(text.hasSuffix("two slices of toast with jam"))

        #expect(mealRequestBody(imageJPEG: nil, note: " \n") == nil)
        let transport = FakeTransport()
        await #expect(throws: MealEstimateError.nothingToEstimate) {
            try await MealAnalyzer(transport: transport).estimate(imageJPEG: nil, note: "", apiKey: "sk-test")
        }
        #expect(await transport.lastRequest(host: "api.anthropic.com", path: "/v1/messages") == nil)
    }

    @Test func mapsUnauthorizedToInvalidKey() async {
        let transport = FakeTransport()
        await transport.stub(host: "api.anthropic.com", path: "/v1/messages", status: 401, json: #"{"type":"error"}"#)

        let analyzer = MealAnalyzer(transport: transport)
        await #expect(throws: ClaudeAPIError.invalidAPIKey) {
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

    @Test func upsertEditsInPlaceKeepsTimeOrderAndDeleteRemovesById() {
        let store = InMemoryMealStore()
        let start = Date(timeIntervalSince1970: 1_791_800_000)
        let breakfast = Meal(timestamp: start, carbsGrams: 40, summary: "Breakfast")
        let lunch = Meal(timestamp: start.addingTimeInterval(4 * 3600), carbsGrams: 55, summary: "Lunch")
        store.upsert(lunch)
        #expect(store.upsert(breakfast).map(\.summary) == ["Breakfast", "Lunch"])

        let movedBreakfast = Meal(id: breakfast.id, timestamp: start.addingTimeInterval(5 * 3600), carbsGrams: 45, summary: "Late breakfast")
        #expect(store.upsert(movedBreakfast) == [lunch, movedBreakfast])

        #expect(store.delete(id: lunch.id) == [movedBreakfast])
        #expect(store.delete(id: UUID()) == [movedBreakfast])
    }
}

@Suite struct MealPhotoTests {
    @Test func downscalesToTheLongEdgeWithoutUpscaling() throws {
        let large = try #require(mealPhotoJPEG(from: pngData(width: 3000, height: 2000), maxDimension: 1280))
        #expect(try pixelSize(large) == [1280, 853])
        let small = try #require(mealPhotoJPEG(from: pngData(width: 400, height: 300), maxDimension: 1280))
        #expect(try pixelSize(small) == [400, 300])
        #expect(mealPhotoJPEG(from: Data("not an image".utf8)) == nil)
    }

    private func pngData(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func pixelSize(_ data: Data) throws -> [Int] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return [properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0]
    }
}
