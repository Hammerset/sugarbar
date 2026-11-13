import Foundation
import Testing

@testable import SugarbarCore

/// Generates History from known sensitivity and carb ratio: a user eating three meals a day,
/// dosing from their own (possibly wrong) beliefs, correcting at night when high.
private struct Simulation {
    var days = 28
    var trueSensitivity: (Double) -> Double = { _ in 2.5 }
    var trueCarbRatio: (Double) -> Double = { _ in 8 }
    var beliefSensitivity = 3.0
    var beliefCarbRatio = 10.0
    var sensorNoise = 0.0
    var drift = 0.0
    var unloggedSnacksPerDay = 0.0
    var unloggedMealShare = 0.0
    var nightCorrections = true
    var trueInsulinPeak: TimeInterval = 75 * 60
    var seed: UInt64 = 1

    static let start = Date(timeIntervalSince1970: 1_700_006_400)
    var now: Date { Self.start.addingTimeInterval(Double(days) * 86400 + 13 * 3600) }

    struct Output {
        var readings: [Reading] = []
        var doses: [InsulinDose] = []
        var meals: [Meal] = []
    }

    private struct Carbs { let start: Date; let grams: Double; let absorption: Double; let rise: Double }
    private struct Insulin { let start: Date; let units: Double; let sensitivity: Double }

    func run() -> Output {
        var rng = SplitMix(seed: seed)
        let model = ExponentialInsulinModel(peak: trueInsulinPeak, duration: 6 * 3600)
        var output = Output()
        var carbs: [Carbs] = []
        var insulin: [Insulin] = []
        var base = 6.5
        var driftLevel = 0.0
        var lastTreatment = Date.distantPast
        var lastBolus = Date.distantPast
        var snackTimes: [Date] = []

        func effect(at date: Date) -> Double {
            let carbRise = carbs.reduce(0) { total, c in
                total + c.grams * c.rise * min(max(date.timeIntervalSince(c.start) / c.absorption, 0), 1)
            }
            let drop = insulin.reduce(0) { $0 + $1.units * $1.sensitivity * (1 - model.remainingFraction(after: date.timeIntervalSince($1.start))) }
            return carbRise - drop
        }

        func dose(_ units: Double, at date: Date) {
            let rounded = (units * 2).rounded() / 2
            guard rounded > 0 else { return }
            let day = date.timeIntervalSince(Self.start) / 86400
            insulin.append(Insulin(start: date, units: rounded, sensitivity: trueSensitivity(day)))
            output.doses.append(InsulinDose(kind: .bolus, units: rounded, timestamp: date, insulinName: "NovoRapid", deviceName: "NovoPen 6"))
            lastBolus = date
        }

        func eat(_ grams: Double, at date: Date, absorption: Double) {
            let day = date.timeIntervalSince(Self.start) / 86400
            carbs.append(Carbs(start: date, grams: grams, absorption: absorption, rise: trueSensitivity(day) / trueCarbRatio(day)))
        }

        let step: TimeInterval = 5 * 60
        var date = Self.start
        let end = Self.start.addingTimeInterval(Double(days) * 86400 + 13 * 3600)
        while date <= end {
            let secondOfDay = Int(date.timeIntervalSince(Self.start)) % 86400
            if secondOfDay == 0 {
                snackTimes = rng.uniform() < unloggedSnacksPerDay ? [date.addingTimeInterval(rng.uniform(9, 21) * 3600).floored(to: step)] : []
            }
            let glucose = base + effect(at: date) + driftLevel

            for (hour, minimum, maximum) in [(7, 30.0, 70.0), (12, 40.0, 80.0), (18, 50.0, 90.0)] where secondOfDay == hour * 3600 {
                let grams = rng.uniform(minimum, maximum).rounded()
                eat(grams, at: date, absorption: rng.uniform(2, 3) * 3600)
                if rng.uniform() >= unloggedMealShare {
                    output.meals.append(Meal(timestamp: date, carbsGrams: grams, summary: "meal"))
                }
                dose(grams / beliefCarbRatio + max(0, glucose - 7) / beliefSensitivity, at: date)
            }
            if nightCorrections, secondOfDay == 22 * 3600 + 30 * 60, glucose > 10, date.timeIntervalSince(lastBolus) > 3 * 3600 {
                dose((glucose - 6) / beliefSensitivity, at: date)
            }
            if snackTimes.contains(date) {
                eat(rng.uniform(15, 35).rounded(), at: date, absorption: 90 * 60)
            }
            if glucose < 3.6, date.timeIntervalSince(lastTreatment) > 30 * 60 {
                eat(15, at: date, absorption: 20 * 60)
                lastTreatment = date
            }

            let measured = glucose + rng.normal() * sensorNoise
            output.readings.append(Reading(value: min(max(measured, 2.3), 27), timestamp: date, trend: .notDetermined))

            driftLevel = 0.97 * driftLevel + rng.normal() * drift
            let settledCarbs = carbs.filter { date.timeIntervalSince($0.start) >= $0.absorption }
            let settledInsulin = insulin.filter { date.timeIntervalSince($0.start) >= 6 * 3600 }
            base += settledCarbs.reduce(0) { $0 + $1.grams * $1.rise } - settledInsulin.reduce(0) { $0 + $1.units * $1.sensitivity }
            carbs.removeAll { date.timeIntervalSince($0.start) >= $0.absorption }
            insulin.removeAll { date.timeIntervalSince($0.start) >= 6 * 3600 }
            date.addTimeInterval(step)
        }
        return output
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * uniform() }
    mutating func normal() -> Double { sqrt(-2 * log(max(uniform(), 1e-12))) * cos(2 * .pi * uniform()) }
}

private extension Date {
    func floored(to step: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 / step).rounded(.down) * step)
    }
}

private let utc = TimeZone(identifier: "UTC")!

private func estimate(_ simulation: Simulation, therapy: TherapySettings = TherapySettings()) -> TherapyEstimate {
    let output = simulation.run()
    return estimateTherapy(
        readings: output.readings,
        doses: output.doses,
        meals: output.meals,
        therapy: therapy,
        thresholds: .standard,
        now: simulation.now,
        timeZone: utc
    )
}

private func relativeError(_ value: Double?, _ truth: Double) -> Double {
    guard let value else { return .infinity }
    return abs(value / truth - 1)
}

@Suite struct TherapyEstimatorTests {
    @Test func recoversSensitivityAndCarbRatioFromCleanHistory() throws {
        let result = estimate(Simulation())
        let sensitivity = try #require(result.sensitivity)
        let carbRatio = try #require(result.carbRatio)
        #expect(relativeError(sensitivity.value, 2.5) < 0.03)
        #expect(relativeError(carbRatio.value, 8) < 0.03)
        #expect(sensitivity.hasEnoughEvidence && carbRatio.hasEnoughEvidence)
        #expect(result.carbRatioBasis == .estimatedSensitivity(sensitivity.value))
        #expect(result.suggestions.map(\.quantity) == [.insulinSensitivity, .carbRatio])
    }

    @Test func recoversThemDespiteNoiseDriftAndUnloggedFood() throws {
        for seed in 1...5 as ClosedRange<UInt64> {
            let simulation = Simulation(sensorNoise: 0.3, drift: 0.08, unloggedSnacksPerDay: 0.3, unloggedMealShare: 0.1, seed: seed)
            let result = estimate(simulation)
            #expect(relativeError(result.sensitivity?.value, 2.5) < 0.08, "seed \(seed)")
            #expect(relativeError(result.carbRatio?.value, 8) < 0.08, "seed \(seed)")
            #expect((result.rejections[.unexplainedRise] ?? 0) > 0)
        }
    }

    @Test func followsACarbRatioThatShiftsOverTwoWeeks() throws {
        let simulation = Simulation(
            trueCarbRatio: { day in day < 14 ? 10 : 10 - 2 * min((day - 14) / 14, 1) },
            sensorNoise: 0.3,
            drift: 0.08,
            unloggedSnacksPerDay: 0.3
        )
        let result = estimate(simulation, therapy: TherapySettings(insulinSensitivity: 2.5, carbRatio: 10))
        let carbRatio = try #require(result.carbRatio?.value)
        #expect(carbRatio > 8.5 && carbRatio < 9.3)
        #expect(result.suggestions.first { $0.quantity == .carbRatio }.map { [$0.current, $0.suggested] } == [10, 9])
    }

    @Test func mealsAloneGiveNoCarbRatioWithoutASensitivity() throws {
        let simulation = Simulation(nightCorrections: false)
        let unknown = estimate(simulation)
        #expect(unknown.sensitivity == nil)
        #expect(unknown.carbRatio == nil)
        #expect(unknown.unresolvedMealEpisodes > 10)
        #expect(unknown.suggestions.isEmpty)

        let assumed = estimate(simulation, therapy: TherapySettings(insulinSensitivity: 2.5))
        #expect(assumed.carbRatioBasis == .workingSensitivity(2.5))
        #expect(relativeError(assumed.carbRatio?.value, 8) < 0.03)
    }

    @Test func rejectsCorrectionsSpoiledByUnloggedCarbsOrTreatedLows() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let model = ExponentialInsulinModel(peak: 75 * 60, duration: 6 * 3600)
        func history(units: Double, from glucose: Double, carbs: (at: TimeInterval, rise: Double)?) -> [Reading] {
            stride(from: -3600.0, through: 6 * 3600, by: 300).map { t in
                var value = glucose - units * 2.5 * (1 - model.remainingFraction(after: t))
                if let carbs { value += carbs.rise * min(max((t - carbs.at) / 1800, 0), 1) }
                return Reading(value: value, timestamp: start.addingTimeInterval(t), trend: .notDetermined)
            }
        }
        let dose = [InsulinDose(kind: .bolus, units: 2, timestamp: start, insulinName: nil, deviceName: nil)]
        let lowDose = [InsulinDose(kind: .bolus, units: 5, timestamp: start, insulinName: nil, deviceName: nil)]
        func run(_ readings: [Reading], _ doses: [InsulinDose]) -> TherapyEstimate {
            estimateTherapy(readings: readings, doses: doses, meals: [], therapy: TherapySettings(), thresholds: .standard, now: start.addingTimeInterval(2 * 86400))
        }

        #expect(run(history(units: 2, from: 12, carbs: nil), dose).sensitivity?.episodes.count == 1)
        #expect(run(history(units: 2, from: 12, carbs: (5400, 4)), dose).rejections[.unexplainedRise] == 1)
        #expect(run(history(units: 5, from: 11, carbs: (8400, 3)), lowDose).rejections[.treatedLow] == 1)
        #expect(run(history(units: 2, from: 8, carbs: nil), dose).rejections[.notAboveRange] == 1)
    }

    @Test func suggestionsNeedAMarginAndStayDismissedUntilTheEstimateMoves() throws {
        let result = estimate(Simulation(), therapy: TherapySettings(insulinSensitivity: 2.5, carbRatio: 8.3))
        #expect(result.suggestions.isEmpty)

        let off = estimate(Simulation(), therapy: TherapySettings(insulinSensitivity: 2.5, carbRatio: 10))
        let suggestion = try #require(off.suggestions.first)
        #expect(suggestion.text == "Carb ratio looks closer to 1 u per 8 g (now 10), from \(suggestion.evidence).")

        var settings = Settings.default
        settings.therapy = TherapySettings(insulinSensitivity: 2.5, carbRatio: 10)
        let dismissed = settings.dismissing(suggestion)
        #expect(dismissed.visibleSuggestions(off).isEmpty)
        let moved = TherapySuggestion(quantity: .carbRatio, current: 10, suggested: 7, episodeCount: 6, days: 10)
        let later = TherapyEstimate(computedAt: Date(), sensitivity: nil, carbRatio: nil, carbRatioBasis: nil, unresolvedMealEpisodes: 0, rejections: [:], suggestions: [moved])
        #expect(dismissed.visibleSuggestions(later) == [moved])

        let accepted = dismissed.accepting(moved, at: Date())
        #expect(accepted.therapy.carbRatio == 7)
        #expect(accepted.therapyLearning.changes.last?.old == 10)
        #expect(accepted.therapyLearning.dismissed[.carbRatio] == nil)
        #expect(accepted.visibleSuggestions(later).isEmpty)
    }

    @Test func plannedMealsAreNotEvidenceUntilEaten() {
        let date = Date(timeIntervalSince1970: 1_794_488_820)
        #expect(mealCountsAsEvidence(Meal(timestamp: date, carbsGrams: 60, summary: "Pizza")))
        #expect(!mealCountsAsEvidence(Meal(timestamp: date, carbsGrams: 60, summary: "Pizza", state: .planned)))
        #expect(!mealCountsAsEvidence(Meal(timestamp: date, carbsGrams: 0, summary: "Coffee")))
    }

    @Test func aSingleEpisodeHasNoErrorFigure() {
        #expect(formatRelativeError(.infinity) == "error unknown")
        #expect(formatRelativeError(0.084) == "±8%")
    }
}
