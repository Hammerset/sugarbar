import Foundation
import Testing

@testable import SugarbarCore

private let strategyJSON = """
{"timing": "Inject about 15 minutes before eating; glucose is above target and stable.",
 "preBolusMinutes": 15,
 "split": {"nowUnits": 4, "laterUnits": 2, "laterAfterMinutes": 60, "reason": "Pizza is high in fat."},
 "recommendedUnits": 6,
 "differenceReason": null,
 "watchFor": ["A late rise 3 hours after eating"],
 "recheckAfterMinutes": 120,
 "cautions": []}
"""

@Suite struct MealStrategyTests {
    @Test func parsesTheStructuredStrategyWhereverItIs() throws {
        let expected = MealStrategy(
            timing: "Inject about 15 minutes before eating; glucose is above target and stable.",
            preBolusMinutes: 15,
            split: .init(nowUnits: 4, laterUnits: 2, laterAfterMinutes: 60, reason: "Pizza is high in fat."),
            recommendedUnits: 6,
            watchFor: ["A late rise 3 hours after eating"],
            recheckAfterMinutes: 120
        )
        #expect(try parseMealStrategy(strategyJSON, appUnits: 6) == expected)
        #expect(try parseMealStrategy("```json\n\(strategyJSON)\n```", appUnits: 6) == expected)
        #expect(expected.laterNote == "2 u about 60 min after starting to eat")
        #expect(!expected.differs(from: 6))
    }

    @Test func keepsADifferentAmountOnlyWithAReason() throws {
        let unexplained = try parseMealStrategy(#"{"timing": "At the first bite.", "recommendedUnits": 4, "split": {"nowUnits": 2, "laterUnits": 2}}"#, appUnits: 6)
        #expect(unexplained.recommendedUnits == nil)
        #expect(unexplained.split == nil)
        #expect(unexplained.timing == "At the first bite.")

        let explained = try parseMealStrategy(#"{"timing": "At the first bite.", "recommendedUnits": "5", "differenceReason": "Glucose is falling.", "watchFor": "Lows after 2 hours"}"#, appUnits: 6)
        #expect(explained.recommendedUnits == 5)
        #expect(explained.differs(from: 6))
        #expect(explained.watchFor == ["Lows after 2 hours"])
    }

    @Test func fallsBackToPlainTextAndRejectsAnEmptyReply() throws {
        let prose = "Inject at the first bite and check again in two hours."
        #expect(try parseMealStrategy(prose, appUnits: 6) == MealStrategy(plainText: prose))
        #expect(try parseMealStrategy(#"{"unexpected": true}"#, appUnits: 6).plainText == #"{"unexpected": true}"#)
        #expect(throws: ClaudeAPIError.unexpectedResponse) { try parseMealStrategy("  \n", appUnits: 6) }
    }

    @Test func promptCarriesTheCalculationMealAndMoment() throws {
        let now = Date(timeIntervalSince1970: 1_794_488_820)
        let input = DoseSuggestionInput(
            carbsGrams: 60,
            therapy: TherapySettings(insulinSensitivity: 2.5, carbRatio: 10),
            dosing: .default,
            thresholds: .standard,
            latest: Reading(value: 9.0, timestamp: now.addingTimeInterval(-120), trend: .rising),
            sensorActivation: nil,
            insulinOnBoard: 1.2,
            now: now
        )
        let context = MealStrategyContext(
            description: "Two slices of pepperoni pizza",
            estimate: MealEstimate(carbsGrams: 62, items: ["Pizza, 2 slices"], assumptions: [], confidence: "medium", fatGrams: 28, proteinGrams: 24, energyKcal: 610, absorption: .slow),
            carbsGrams: 60,
            suggestion: suggestDose(input),
            dosing: .default,
            therapy: input.therapy,
            thresholds: .standard,
            latest: input.latest,
            forecast: nil,
            history: "# Glucose, insulin and meal history\n…",
            now: now
        )
        let prompt = mealStrategyPrompt(context)
        #expect(prompt.contains("Claude's Estimate: 62 g carbs, fat 28 g · protein 24 g · 610 kcal · slow absorption, confidence medium"))
        #expect(prompt.contains("Meal part: 60 g ÷ 10 g per u = 6.0 u"))
        #expect(prompt.contains("Correction part: (9.0 − target 6.0) ÷ 2.5 mmol/L per u = 1.2 u"))
        #expect(prompt.contains("Insulin on Board deducted: 1.2 u of 1.2 u"))
        #expect(prompt.contains("rounded down to the 1 u pen step = 6 u"))
        #expect(prompt.contains("Glucose 9.0 mmol/L, Trend rising, 2 min old."))

        let body = mealStrategyRequestBody(context)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect((body["system"] as? String)?.contains("Recommend a different total only for a specific reason") == true)
    }
}
