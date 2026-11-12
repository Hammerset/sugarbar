import Foundation

public let mealStrategyModel = "claude-opus-5-5"

/// Claude's advice on how to take the dose for a planned Meal. When the reply is not the JSON asked for,
/// only `plainText` is set and the rest is empty.
public struct MealStrategy: Equatable, Sendable {
    public struct Split: Equatable, Sendable {
        public let nowUnits: Double
        public let laterUnits: Double
        public let laterAfterMinutes: Int?
        public let reason: String?

        public init(nowUnits: Double, laterUnits: Double, laterAfterMinutes: Int?, reason: String?) {
            self.nowUnits = nowUnits
            self.laterUnits = laterUnits
            self.laterAfterMinutes = laterAfterMinutes
            self.reason = reason
        }
    }

    public var timing: String?
    /// Minutes before the first bite; negative means after starting to eat.
    public var preBolusMinutes: Int?
    public var split: Split?
    /// Claude's total, kept only when it matches the app's calculation or comes with a reason.
    public var recommendedUnits: Double?
    public var differenceReason: String?
    public var watchFor: [String]
    public var recheckAfterMinutes: Int?
    public var cautions: [String]
    public var plainText: String?

    public init(
        timing: String? = nil,
        preBolusMinutes: Int? = nil,
        split: Split? = nil,
        recommendedUnits: Double? = nil,
        differenceReason: String? = nil,
        watchFor: [String] = [],
        recheckAfterMinutes: Int? = nil,
        cautions: [String] = [],
        plainText: String? = nil
    ) {
        self.timing = timing
        self.preBolusMinutes = preBolusMinutes
        self.split = split
        self.recommendedUnits = recommendedUnits
        self.differenceReason = differenceReason
        self.watchFor = watchFor
        self.recheckAfterMinutes = recheckAfterMinutes
        self.cautions = cautions
        self.plainText = plainText
    }

    /// True when Claude recommends a total that differs from the app's by at least a quarter unit.
    public func differs(from appUnits: Double?) -> Bool {
        guard let recommendedUnits else { return false }
        guard let appUnits else { return true }
        return abs(recommendedUnits - appUnits) >= 0.25
    }

    /// One line for a saved Meal Plan.
    public var summaryLine: String? {
        if let plainText { return plainText.components(separatedBy: .newlines).first }
        return timing
    }

    /// When to take the second part of a split dose, for the reminder on the plan.
    public var laterNote: String? {
        guard let split, split.laterUnits > 0 else { return nil }
        let when = split.laterAfterMinutes.map { "about \($0) min after starting to eat" } ?? "later"
        return "\(formatUnits(split.laterUnits)) u \(when)"
    }
}

/// Everything the strategy request tells Claude about this meal and the moment.
public struct MealStrategyContext: Sendable {
    public var description: String
    public var estimate: MealEstimate?
    public var carbsGrams: Double
    public var suggestion: DoseSuggestion
    public var dosing: DosingSettings
    public var therapy: TherapySettings
    public var thresholds: Thresholds
    public var latest: Reading?
    public var forecast: Forecast?
    public var history: String
    public var now: Date

    public init(
        description: String,
        estimate: MealEstimate?,
        carbsGrams: Double,
        suggestion: DoseSuggestion,
        dosing: DosingSettings,
        therapy: TherapySettings,
        thresholds: Thresholds,
        latest: Reading?,
        forecast: Forecast?,
        history: String,
        now: Date
    ) {
        self.description = description
        self.estimate = estimate
        self.carbsGrams = carbsGrams
        self.suggestion = suggestion
        self.dosing = dosing
        self.therapy = therapy
        self.thresholds = thresholds
        self.latest = latest
        self.forecast = forecast
        self.history = history
        self.now = now
    }
}

/// How many days of History the strategy request includes.
public let mealStrategyHistoryDays = 3

public actor MealStrategist {
    private let client: ClaudeClient

    public init(transport: HTTPTransport) {
        self.client = ClaudeClient(transport: transport)
    }

    public func strategy(for context: MealStrategyContext, apiKey: String) async throws -> MealStrategy {
        let reply = try await client.send(body: mealStrategyRequestBody(context), apiKey: apiKey, timeout: 180)
        return try parseMealStrategy(reply.text, appUnits: context.suggestion.dose?.units)
    }
}

func mealStrategyRequestBody(_ context: MealStrategyContext) -> [String: Any] {
    [
        "model": mealStrategyModel,
        "max_tokens": 16000,
        "output_config": ["effort": "medium"],
        "system": mealStrategySystemPrompt,
        "messages": [["role": "user", "content": mealStrategyPrompt(context)]],
    ]
}

let mealStrategySystemPrompt = """
You help one adult with type 1 diabetes on pen therapy (a rapid-acting bolus pen, NovoRapid, and long-acting basal, Tresiba) decide how to take insulin for a meal they are about to eat. Their app has already calculated a dose from their own carb ratio, insulin sensitivity, target glucose and Insulin on Board; you get that calculation with its parts, the meal, their current glucose and Trend, the app's Forecast and recent history. The app is not a medical device and the user makes the decision; your job is a short, practical strategy.

Reply with only a JSON object, no prose and no code fence, with these keys:
{"timing": <one sentence: when to inject relative to starting to eat, given the current level and Trend>,
 "preBolusMinutes": <integer minutes between injecting and the first bite; 0 = at the first bite; negative = after starting to eat>,
 "split": <null, or {"nowUnits": <number>, "laterUnits": <number>, "laterAfterMinutes": <integer minutes after starting to eat>, "reason": <one short sentence>}>,
 "recommendedUnits": <total units you recommend: the app's calculated amount unless you have a specific reason>,
 "differenceReason": <null, or one sentence on why your total differs from the app's calculation>,
 "watchFor": [<short things to watch, e.g. a late rise 2–3 hours after a fatty meal>],
 "recheckAfterMinutes": <integer minutes after starting to eat to check glucose again>,
 "cautions": [<short cautions, e.g. recent lows, large Insulin on Board, low confidence in the carb estimate; empty if none>]}

Rules:
- Start from the app's calculation. Recommend a different total only for a specific reason you can point to in the data (a falling or rising Trend, repeated lows or late highs after similar meals, a lot of fat or protein, a low-confidence carb estimate), keep the difference modest, and always fill differenceReason when you do.
- Never exceed the maximum single dose. Use multiples of the pen step for every amount.
- Suggest a split only for slow meals (high fat or protein, slow absorption) or when the history shows late rises; nowUnits + laterUnits must equal recommendedUnits.
- Inject closer to the meal, or at the first bite, when glucose is low-normal or falling; allow a longer pre-bolus when it is high or rising and the meal is fast.
- If no dose was calculated, do not invent one: set recommendedUnits to null, and give timing and what to watch for based on why it was withheld (for example treat a low first).
- Keep every text field to one short sentence, in plain language.
"""

/// The user message of the strategy request.
public func mealStrategyPrompt(_ context: MealStrategyContext) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    var lines: [String] = ["# Meal about to be eaten"]
    let description = context.description.trimmingCharacters(in: .whitespacesAndNewlines)
    lines.append("Description: \(description.isEmpty ? "not given" : description)")
    lines.append("Carbs the user is counting: \(formatGrams(context.carbsGrams)) g")
    if let estimate = context.estimate {
        var estimateLine = "Claude's Estimate: \(formatGrams(estimate.carbsGrams)) g carbs"
        if let macros = macroLine(fat: estimate.fatGrams, protein: estimate.proteinGrams, energy: estimate.energyKcal, absorption: estimate.absorption) {
            estimateLine += ", " + macros
        }
        estimateLine += ", confidence \(estimate.confidence)"
        lines.append(estimateLine)
        if !estimate.items.isEmpty { lines.append("Foods: " + estimate.items.joined(separator: "; ")) }
        if !estimate.assumptions.isEmpty { lines.append("Assumed: " + estimate.assumptions.joined(separator: "; ")) }
    }

    lines.append("")
    lines.append("# The app's dose calculation")
    switch context.suggestion {
    case let .suggested(dose):
        lines.append("Meal part: \(formatGrams(dose.carbsGrams)) g ÷ \(number(dose.carbRatio)) g per u = \(units(dose.mealUnits)) u")
        lines.append("Correction part: (\(formatMmolPerL(dose.currentGlucose)) − target \(formatMmolPerL(dose.targetGlucose))) ÷ \(number(dose.insulinSensitivity)) mmol/L per u = \(units(dose.correctionUnits)) u")
        lines.append("Insulin on Board deducted: \(units(dose.insulinOnBoardDeduction)) u of \(units(dose.insulinOnBoard)) u")
        var total = "Total: \(units(dose.unroundedUnits)) u, rounded down to the \(formatUnits(dose.penStep)) u pen step = \(formatUnits(dose.units)) u"
        if dose.wasCapped { total += " (capped at the maximum single dose)" }
        lines.append(total)
    case let .withheld(reasons):
        lines.append("No dose calculated: " + reasons.map(\.message).joined(separator: " "))
    }
    lines.append("Pen step \(formatUnits(context.dosing.penStep)) u; maximum single dose \(formatUnits(context.dosing.maxSingleDose)) u; target \(formatMmolPerL(context.dosing.targetGlucose)) mmol/L; insulin action \(number(context.therapy.insulinDuration / 3600)) h, peak \(Int(context.therapy.insulinPeak / 60)) min.")

    lines.append("")
    lines.append("# Now (\(formatter.string(from: context.now)) local time)")
    if let latest = context.latest {
        let age = Int(max(0, context.now.timeIntervalSince(latest.timestamp)) / 60)
        lines.append("Glucose \(formatMmolPerL(latest.value)) mmol/L, Trend \(latest.trend.label), \(age) min old. Low threshold \(formatMmolPerL(context.thresholds.low)), high \(formatMmolPerL(context.thresholds.high)).")
    } else {
        lines.append("No current Reading.")
    }
    if let forecast = context.forecast {
        var line = "Forecast (before this meal and dose): Insulin on Board \(units(forecast.insulinOnBoard)) u, Carbs on Board \(formatGrams(forecast.carbsOnBoard)) g"
        if forecast.eventual.isFinite { line += ", settling around \(formatMmolPerL(forecast.eventual))" }
        if let low = forecast.lowCrossing { line += ", predicted below \(formatMmolPerL(context.thresholds.low)) at \(formatter.string(from: low))" }
        if let high = forecast.highCrossing { line += ", predicted above \(formatMmolPerL(context.thresholds.high)) at \(formatter.string(from: high))" }
        lines.append(line + ".")
    } else {
        lines.append("No Forecast available.")
    }

    lines.append("")
    lines.append("# Recent history")
    lines.append(context.history.trimmingCharacters(in: .whitespacesAndNewlines))
    return lines.joined(separator: "\n")
}

/// Accepts the JSON object wherever the model put it; any other non-empty reply becomes plain text.
/// A total that differs from `appUnits` without a reason is dropped.
func parseMealStrategy(_ text: String, appUnits: Double?) throws -> MealStrategy {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ClaudeAPIError.unexpectedResponse }
    guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
          let object = try? JSONSerialization.jsonObject(with: Data(trimmed[start...end].utf8)) as? [String: Any]
    else { return MealStrategy(plainText: trimmed) }

    var strategy = MealStrategy(
        timing: string(object["timing"]),
        preBolusMinutes: double(object["preBolusMinutes"]).map { Int($0.rounded()) },
        recommendedUnits: double(object["recommendedUnits"]),
        differenceReason: string(object["differenceReason"]),
        watchFor: strings(object["watchFor"]),
        recheckAfterMinutes: double(object["recheckAfterMinutes"]).map { Int($0.rounded()) },
        cautions: strings(object["cautions"])
    )
    if let split = object["split"] as? [String: Any],
       let now = double(split["nowUnits"]), let later = double(split["laterUnits"]), later > 0 {
        strategy.split = .init(
            nowUnits: now,
            laterUnits: later,
            laterAfterMinutes: double(split["laterAfterMinutes"]).map { Int($0.rounded()) },
            reason: string(split["reason"])
        )
    }
    if strategy.differs(from: appUnits), strategy.differenceReason == nil {
        strategy.recommendedUnits = nil
        strategy.split = nil
    }
    if strategy.timing == nil, strategy.recommendedUnits == nil, strategy.watchFor.isEmpty, strategy.cautions.isEmpty {
        return MealStrategy(plainText: trimmed)
    }
    return strategy
}

private func string(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
}

private func strings(_ value: Any?) -> [String] {
    if let single = string(value) { return [single] }
    return (value as? [Any])?.compactMap { string($0) } ?? []
}

private func double(_ value: Any?) -> Double? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
    if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
    return nil
}

private func units(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func number(_ value: Double) -> String {
    value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
}
