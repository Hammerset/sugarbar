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
        #expect(try parseMealStrategy(strategyJSON, appUnits: 6, dosing: .default) == expected)
        #expect(try parseMealStrategy("```json\n\(strategyJSON)\n```", appUnits: 6, dosing: .default) == expected)
        #expect(expected.laterNote == "2 u about 60 min after starting to eat")
        #expect(!expected.differs(from: 6))
    }

    @Test func keepsADifferentAmountOnlyWithAReason() throws {
        let unexplained = try parseMealStrategy(#"{"timing": "At the first bite.", "recommendedUnits": 4, "split": {"nowUnits": 2, "laterUnits": 2}}"#, appUnits: 6, dosing: .default)
        #expect(unexplained.recommendedUnits == nil)
        #expect(unexplained.split == nil)
        #expect(unexplained.timing == "At the first bite.")

        let explained = try parseMealStrategy(#"{"timing": "At the first bite.", "recommendedUnits": "5", "differenceReason": "Glucose is falling.", "watchFor": "Lows after 2 hours"}"#, appUnits: 6, dosing: .default)
        #expect(explained.recommendedUnits == 5)
        #expect(explained.differs(from: 6))
        #expect(explained.watchFor == ["Lows after 2 hours"])
    }

    @Test func fallsBackToPlainTextAndRejectsAnEmptyReply() throws {
        let prose = "Inject at the first bite and check again in two hours."
        #expect(try parseMealStrategy(prose, appUnits: 6, dosing: .default) == MealStrategy(plainText: prose))
        #expect(try parseMealStrategy(#"{"unexpected": true}"#, appUnits: 6, dosing: .default).plainText == #"{"unexpected": true}"#)
        #expect(throws: ClaudeAPIError.unexpectedResponse) { try parseMealStrategy("  \n", appUnits: 6, dosing: .default) }
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

    private func amounts(_ json: String, app: Double?, dosing: DosingSettings = .default) throws -> MealStrategy {
        try parseMealStrategy(json, appUnits: app, dosing: dosing)
    }

    @Test func dropsAmountsThatBreakTheDoseLimitsAndSaysWhy() throws {
        let overMax = try amounts(#"{"timing": "Now.", "recommendedUnits": 16, "differenceReason": "Rising fast."}"#, app: 14)
        #expect(overMax.recommendedUnits == nil && overMax.differenceReason == nil)
        #expect(overMax.timing == "Now.")
        #expect(overMax.cautions == ["Claude's amount was ignored because it was above your maximum single dose of 15 u."])

        let splitOverMax = try amounts(#"{"timing": "Now.", "recommendedUnits": 14, "split": {"nowUnits": 10, "laterUnits": 6}}"#, app: 14)
        #expect(splitOverMax.recommendedUnits == nil && splitOverMax.split == nil)
        #expect(splitOverMax.cautions.first?.contains("maximum single dose") == true)

        let negative = try amounts(#"{"timing": "Now.", "recommendedUnits": -1, "differenceReason": "Low."}"#, app: 2)
        #expect(negative.recommendedUnits == nil)
        #expect(negative.cautions.first?.contains("negative") == true)

        let offStep = try amounts(#"{"timing": "Now.", "recommendedUnits": 6.5, "differenceReason": "Fatty."}"#, app: 6)
        #expect(offStep.recommendedUnits == nil)
        #expect(offStep.cautions.first?.contains("multiple of the 1 u pen step") == true)
        #expect(try amounts(#"{"timing": "Now.", "recommendedUnits": 6.5, "differenceReason": "Fatty."}"#, app: 6, dosing: DosingSettings(penStep: 0.5)).recommendedUnits == 6.5)
    }

    @Test func allowsAnyLowerTotalButOnlyModestlyHigherOnes() throws {
        #expect(try amounts(#"{"timing": "Now.", "recommendedUnits": 2, "differenceReason": "Falling."}"#, app: 10).recommendedUnits == 2)
        #expect(try amounts(#"{"timing": "Now.", "recommendedUnits": 12, "differenceReason": "Fatty."}"#, app: 10).recommendedUnits == 12)
        let tooHigh = try amounts(#"{"timing": "Now.", "recommendedUnits": 13, "differenceReason": "Fatty."}"#, app: 10)
        #expect(tooHigh.recommendedUnits == nil)
        #expect(tooHigh.cautions == ["Claude's amount was ignored because it was too far above the app's calculation of 10 u."])

        #expect(try amounts(#"{"timing": "Now.", "recommendedUnits": 3, "differenceReason": "Rising."}"#, app: 2).recommendedUnits == 3)
        #expect(try amounts(#"{"timing": "Now.", "recommendedUnits": 4, "differenceReason": "Rising."}"#, app: 2).recommendedUnits == nil)
    }

    @Test func showsNoClaudeAmountWhenTheAppWithheldTheDose() throws {
        let withheld = try amounts(#"{"timing": "Treat the low first.", "recommendedUnits": 4, "differenceReason": "Meal.", "split": {"nowUnits": 2, "laterUnits": 2}}"#, app: nil)
        #expect(withheld.recommendedUnits == nil && withheld.split == nil && withheld.differenceReason == nil)
        #expect(withheld.timing == "Treat the low first.")
        #expect(withheld.cautions.isEmpty)
        #expect(!withheld.differs(from: nil))
    }

    @Test func flagsPossiblyMissingPenDosesAndTellsClaude() {
        let now = Date(timeIntervalSince1970: 1_794_488_820)
        func pen(_ hoursAgo: Double) -> InsulinDose {
            InsulinDose(kind: .bolus, units: 4, timestamp: now.addingTimeInterval(-hoursAgo * 3600), insulinName: "NovoRapid", deviceName: "NovoPen 6")
        }
        let entered = InsulinDose.manual(kind: .bolus, units: 3, timestamp: now.addingTimeInterval(-3600), insulinName: nil)

        #expect(!doseCoverage([pen(2)], now: now).mayBeMissingDoses)
        #expect(doseCoverage([pen(7)], now: now) == DoseCoverage(newestPenDose: pen(7).timestamp, mayBeMissingDoses: true))
        #expect(!doseCoverage([pen(7), entered], now: now).mayBeMissingDoses)
        #expect(doseCoverage([], now: now).mayBeMissingDoses)

        let context = MealStrategyContext(
            description: "Toast", estimate: nil, carbsGrams: 30, suggestion: .withheld([.noReading]), dosing: .default,
            therapy: .default, thresholds: .standard, latest: nil, forecast: nil, history: "",
            doseCoverage: doseCoverage([pen(7)], now: now), now: now
        )
        let prompt = mealStrategyPrompt(context)
        #expect(prompt.contains("Newest synced pen Dose: 7.0 h ago."))
        #expect(prompt.contains("a recent injection may be missing and Insulin on Board may be too low"))
    }
}
