import Foundation
import Testing

@testable import SugarbarCore

/// History generated from known insulin timing and per-class absorption: three logged meals a
/// day with their Boluses, and an unlogged rise at night that is corrected once it is flat.
private struct Body {
    var days = 21
    var truth = TherapySettings(insulinSensitivity: 3, carbRatio: 10)
    var noise = 0.1
    var seed: UInt64 = 7

    static let start = Date(timeIntervalSince1970: 1_700_006_400)
    var now: Date { Self.start.addingTimeInterval(Double(days) * 86400 + 14 * 3600) }

    func run() -> (readings: [Reading], doses: [InsulinDose], meals: [Meal]) {
        let sensitivity = truth.insulinSensitivity!
        let ratio = truth.carbRatio!
        let model = ExponentialInsulinModel(peak: truth.insulinPeak, duration: truth.insulinDuration)
        var meals: [Meal] = []
        var doses: [InsulinDose] = []
        var rises: [Date] = []
        for day in 0..<days {
            let midnight = Self.start.addingTimeInterval(Double(day) * 86400)
            for (hour, grams, speed) in [(7.5, 30.0, CarbAbsorption.fast), (12.0, 50.0, .normal), (17.0, 70.0, .slow)] {
                let time = midnight.addingTimeInterval(hour * 3600)
                meals.append(Meal(timestamp: time, carbsGrams: grams, summary: "\(speed)", carbAbsorption: speed))
                doses.append(InsulinDose(kind: .bolus, units: grams / ratio, timestamp: time, insulinName: nil, deviceName: nil))
            }
            rises.append(midnight.addingTimeInterval(0.5 * 3600))
            doses.append(InsulinDose(kind: .bolus, units: 4.5 / sensitivity, timestamp: midnight.addingTimeInterval(2 * 3600), insulinName: nil, deviceName: nil))
        }
        var rng = Noise(seed: seed)
        var readings: [Reading] = []
        var t = Self.start.addingTimeInterval(-3 * 3600)
        while t <= now {
            var value = 6.5
            for meal in meals where meal.timestamp <= t {
                value += meal.carbsGrams * sensitivity / ratio * min(t.timeIntervalSince(meal.timestamp) / truth.absorptionTime(meal.carbAbsorption), 1)
            }
            for dose in doses where dose.timestamp <= t {
                value -= dose.units * sensitivity * (1 - model.remainingFraction(after: t.timeIntervalSince(dose.timestamp)))
            }
            for rise in rises where rise <= t {
                value += 4.5 * min(t.timeIntervalSince(rise) / 3600, 1)
            }
            readings.append(Reading(value: value + noise * (rng.uniform() * 2 - 1), timestamp: t, trend: .notDetermined))
            t.addTimeInterval(5 * 60)
        }
        return (readings, doses, meals)
    }
}

private struct Noise {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

@Suite struct ForecastLearningTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var options: ForecastLearningOptions {
        var options = ForecastLearningOptions.default
        options.sampleSpacing = 15 * 60
        options.trendBlendThinning = 4
        return options
    }

    private func learn(_ body: Body, believing therapy: TherapySettings) -> ForecastLearning {
        let data = body.run()
        return learnForecastParameters(
            readings: data.readings, doses: data.doses, meals: data.meals, therapy: therapy,
            thresholds: .standard, now: body.now, options: options, calendar: calendar
        )
    }

    /// Accepts every Suggestion, as a user would over successive weeks, until none are left.
    private func converge(_ body: Body, from start: TherapySettings, rounds: Int = 6) -> (TherapySettings, [ForecastLearning]) {
        var therapy = start
        var history: [ForecastLearning] = []
        for _ in 0..<rounds {
            let learning = learn(body, believing: therapy)
            history.append(learning)
            guard !learning.suggestions.isEmpty else { break }
            for suggestion in learning.suggestions { therapy[suggestion.quantity] = suggestion.suggested }
        }
        return (therapy, history)
    }

    @Test func rightSettingsSuggestNoTimingChanges() {
        let body = Body()
        let learning = learn(body, believing: body.truth)
        let timings: Set<TherapyQuantity> = [.insulinPeak, .insulinDuration, .fastCarbAbsorption, .normalCarbAbsorption, .slowCarbAbsorption]
        #expect(learning.suggestions.filter { timings.contains($0.quantity) }.isEmpty)
        #expect(learning.estimate(.slowCarbAbsorption)?.eventCount ?? 0 >= 15)
        #expect(learning.estimate(.insulinPeak)?.eventCount ?? 0 >= 15)
    }

    @Test func slowMealsAbsorbingSlowerThanAssumedAreFoundInBoundedSteps() throws {
        var body = Body()
        body.truth.slowCarbAbsorptionTime = 6.5 * 3600
        let believed = TherapySettings(insulinSensitivity: 3, carbRatio: 10)

        let first = learn(body, believing: believed)
        let suggestion = try #require(first.suggestions.first { $0.quantity == .slowCarbAbsorption })
        #expect(suggestion.suggested > believed.slowCarbAbsorptionTime)
        #expect(suggestion.suggested <= believed.slowCarbAbsorptionTime * 1.2)
        #expect(!first.suggestions.contains { $0.quantity == .fastCarbAbsorption || $0.quantity == .normalCarbAbsorption })
        #expect(suggestion.text.hasPrefix("Slow / fatty meals seem to absorb over about"))

        let (learned, _) = converge(body, from: believed)
        #expect(abs(learned.slowCarbAbsorptionTime - 6.5 * 3600) <= 0.1 * 6.5 * 3600)
        #expect(learned.fastCarbAbsorptionTime == believed.fastCarbAbsorptionTime)
        #expect(learned.carbAbsorptionTime == believed.carbAbsorptionTime)
    }

    @Test func anEarlierInsulinPeakIsRecoveredFromCorrections() throws {
        var body = Body()
        body.truth.insulinPeak = 55 * 60
        let believed = TherapySettings(insulinSensitivity: 3, carbRatio: 10)

        let first = learn(body, believing: believed)
        let suggestion = try #require(first.suggestions.first { $0.quantity == .insulinPeak })
        #expect(suggestion.suggested < believed.insulinPeak)
        #expect(suggestion.suggested >= believed.insulinPeak * 0.8)
        #expect(suggestion.text.contains("corrections"))
        #expect(!first.suggestions.contains { $0.quantity.carbAbsorption != nil || $0.quantity == .insulinDuration })

        let (learned, _) = converge(body, from: believed)
        #expect(abs(learned.insulinPeak - 55 * 60) <= 10 * 60)
    }

    @Test func aFewDaysAreNotEnoughEvidence() {
        var body = Body()
        body.days = 3
        body.truth.slowCarbAbsorptionTime = 6.5 * 3600
        body.truth.insulinPeak = 55 * 60
        let learning = learn(body, believing: TherapySettings(insulinSensitivity: 3, carbRatio: 10))
        #expect(learning.suggestions.isEmpty)
        let slow = learning.estimate(.slowCarbAbsorption)
        #expect(slow?.best ?? 0 > TherapySettings.default.slowCarbAbsorptionTime)
        #expect(slow?.hasEnoughEvidence == false)
    }

    @Test func candidatesStayWithinTheStepAndTheSettingsRules() {
        let therapy = TherapySettings(insulinSensitivity: 3, carbRatio: 10, insulinDuration: 4 * 3600, insulinPeak: 110 * 60)
        let peaks = candidateValues(.insulinPeak, current: therapy.insulinPeak, therapy: therapy, maximumStep: 0.2)
        #expect(peaks.allSatisfy { abs($0 - therapy.insulinPeak) <= 0.2 * therapy.insulinPeak })
        #expect(peaks.allSatisfy { $0 < 120 * 60 && $0.truncatingRemainder(dividingBy: 300) == 0 })
        let durations = candidateValues(.insulinDuration, current: therapy.insulinDuration, therapy: therapy, maximumStep: 0.2)
        #expect(durations.allSatisfy { $0 > 2 * therapy.insulinPeak && TherapySettings.insulinDurationRange.contains($0) })
    }
}
