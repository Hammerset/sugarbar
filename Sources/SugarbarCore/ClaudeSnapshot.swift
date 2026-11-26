import Foundation

/// Older parts of a long view collapse to one line per day so the Claude Snapshot stays pasteable.
public let claudeSnapshotDetailDays = 3

public let claudeSnapshotQuestion = """
I have type 1 diabetes on pen therapy (rapid-acting bolus, long-acting basal). Using the data below, help me estimate a bolus dose and a strategy for my next meal, and say how uncertain the estimate is.
Next meal: [what, how many carbs, when]
"""

/// A plain-text account of the chart's current range for pasting into a Claude chat: glucose now
/// and in view, every Dose and Meal, what is on board, the Forecast and the Therapy Settings.
public func claudeSnapshot(
    readings: [Reading],
    doses: [InsulinDose],
    meals: [Meal],
    latest: Reading?,
    sensorActivation: Date?,
    forecast: Forecast?,
    forecastReview: ForecastReview?,
    settings: Settings,
    suggestions: [TherapySuggestion],
    window: HistoryWindow,
    now: Date,
    timeZone: TimeZone = .current,
    includesQuestion: Bool = false
) -> String {
    let view = window.interval(endingAt: now)
    let snapshot = SnapshotBuilder(
        readings: readings.filter { view.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp },
        doses: doses.filter { view.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp },
        eaten: eatenMeals(meals).filter { view.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp },
        planned: plannedMeals(meals).filter { $0.timestamp >= now.addingTimeInterval(-6 * 3600) }.sorted { $0.timestamp < $1.timestamp },
        latest: latest,
        sensorActivation: sensorActivation,
        forecast: forecast,
        forecastReview: forecastReview,
        settings: settings,
        suggestions: suggestions,
        window: window,
        now: now,
        timeZone: timeZone
    )
    let text = snapshot.build()
    return includesQuestion ? claudeSnapshotQuestion + "\n\n" + text : text
}

public func claudeSnapshot(
    history: HistoryStore,
    meals: [Meal],
    latest: Reading?,
    sensorActivation: Date?,
    forecast: Forecast?,
    forecastReview: ForecastReview?,
    settings: Settings,
    suggestions: [TherapySuggestion],
    window: HistoryWindow,
    now: Date = Date(),
    includesQuestion: Bool = false
) -> String {
    let view = window.interval(endingAt: now)
    return claudeSnapshot(
        readings: history.readings(in: view),
        doses: history.doses(in: view),
        meals: meals,
        latest: latest,
        sensorActivation: sensorActivation,
        forecast: forecast,
        forecastReview: forecastReview,
        settings: settings,
        suggestions: suggestions,
        window: window,
        now: now,
        includesQuestion: includesQuestion
    )
}

private struct SnapshotBuilder {
    let readings: [Reading]
    let doses: [InsulinDose]
    let eaten: [Meal]
    let planned: [Meal]
    let latest: Reading?
    let sensorActivation: Date?
    let forecast: Forecast?
    let forecastReview: ForecastReview?
    let settings: Settings
    let suggestions: [TherapySuggestion]
    let window: HistoryWindow
    let now: Date
    let timeZone: TimeZone

    private var thresholds: Thresholds { settings.thresholds }
    private var therapy: TherapySettings { settings.therapy }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private var viewStart: Date { now.addingTimeInterval(-window.duration) }

    /// Readings, Doses and Meals after this are listed one by one; before it, one line per day.
    private var detailStart: Date {
        if window.duration <= Double(claudeSnapshotDetailDays) * 86400 { return viewStart }
        let cutoff = calendar.date(byAdding: .day, value: -(claudeSnapshotDetailDays - 1), to: calendar.startOfDay(for: now)) ?? now
        return max(viewStart, cutoff)
    }

    func build() -> String {
        [header(), current(), glucose(), insulin(), food(), onBoard(), therapySection()]
            .joined(separator: "\n\n") + "\n"
    }

    private func header() -> String {
        let offset = timeZone.secondsFromGMT(for: now)
        let utc = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        return [
            "# Sugarbar snapshot, last \(window.label)",
            "Taken \(format(now, "EEE yyyy-MM-dd HH:mm")) local time, \(timeZone.identifier) (\(utc)); covers \(format(viewStart, "EEE HH:mm"))–\(format(now, "HH:mm")).",
            "Units: glucose mmol/L, insulin units (u), carbs grams (g). Doses include pen injections only after the pen is synced over NFC, plus Doses entered by hand in sugarbar, so recent pen Doses may be missing. Meals only if logged.",
        ].joined(separator: "\n")
    }

    private func current() -> String {
        var lines = ["## Now"]
        if let latest {
            var line = "Glucose \(latest.outOfRange?.label ?? mmol(latest.value))"
            if let arrow = latest.trend.arrowText { line += " \(arrow)" }
            line += " \(latest.trend.label)"
            if let rate = rate(at: latest) { line += ", \(String(format: "%+.2f", (rate * 100).rounded() / 100 + 0)) mmol/L per min" }
            line += ", read \(format(latest.timestamp, "HH:mm")) (\(formatAge(latest.age(at: now))))."
            lines.append(line)
            if latest.isStale(at: now) { lines.append("The latest Reading is stale: nothing newer for over \(Int(stalenessThreshold / 60)) min.") }
            if let outOfRange = latest.outOfRange {
                lines.append("The sensor reports \(outOfRange.label): outside its 2.2–27.8 range.")
            }
        } else {
            lines.append("No current Reading.")
        }
        if let remaining = warmUpRemaining(activatedAt: sensorActivation, now: now) {
            lines.append("Sensor warming up: Readings resume in about \(Int((remaining / 60).rounded(.up))) min.")
        }
        lines.append("Bands: urgent low <\(mmol(thresholds.urgentLow)), low <\(mmol(thresholds.low)), high >\(mmol(thresholds.high)), urgent high >\(mmol(thresholds.urgentHigh)).")
        return lines.joined(separator: "\n")
    }

    /// The Forecast's CGM rate, else the change since the Reading closest to 15 minutes before.
    private func rate(at latest: Reading) -> Double? {
        if let rate = forecast?.trendRate { return rate }
        let earlier = readings.filter {
            let gap = latest.timestamp.timeIntervalSince($0.timestamp)
            return gap >= 5 * 60 && gap <= 20 * 60
        }
        guard let reference = earlier.min(by: {
            abs(latest.timestamp.timeIntervalSince($0.timestamp) - 900) < abs(latest.timestamp.timeIntervalSince($1.timestamp) - 900)
        }) else { return nil }
        return (latest.value - reference.value) / (latest.timestamp.timeIntervalSince(reference.timestamp) / 60)
    }

    private func glucose() -> String {
        var lines = ["## Glucose in view"]
        guard !readings.isEmpty else {
            lines.append("No Readings in view.")
            return lines.joined(separator: "\n")
        }
        lines.append(rangeLine(readings))
        let episodes = lowEpisodes(readings, below: thresholds.low)
        if !episodes.isEmpty {
            lines.append("Lows: " + episodes.map {
                "\(format($0.start, "EEE HH:mm"))–\(format($0.end, "HH:mm")) lowest \(mmol($0.nadir.value)) at \(format($0.nadir.timestamp, "HH:mm"))"
            }.joined(separator: "; ") + ".")
        }
        if window.hours <= 24 {
            lines += slotRows(step: window.hours <= 4 ? 5 : 15)
        } else {
            lines += dailyRows()
            lines += hourlyRows()
        }
        return lines.joined(separator: "\n")
    }

    private func rangeLine(_ values: [Reading]) -> String {
        let mean = values.map(\.value).reduce(0, +) / Double(values.count)
        var line = "Mean \(mmol(mean))"
        if let low = values.min(by: { $0.value < $1.value }), let high = values.max(by: { $0.value < $1.value }) {
            line += ", lowest \(mmol(low.value)) at \(format(low.timestamp, "EEE HH:mm")), highest \(mmol(high.value)) at \(format(high.timestamp, "EEE HH:mm"))"
        }
        if let tir = timeInRange(values, thresholds: thresholds) {
            line += "; in range \(percent(tir.percent(.inRange))), below \(percent(tir.percent(.low) + tir.percent(.urgentLow))), above \(percent(tir.percent(.high) + tir.percent(.urgentHigh)))"
        }
        return line + "."
    }

    /// One row per hour, one column per slot: the slot's mean, L when below low, H when above high.
    private func slotRows(step minutes: Int) -> [String] {
        let columns = 60 / minutes
        let header = (0..<columns).map { String(format: ":%02d", $0 * minutes) }.joined(separator: " ")
        var lines = ["Mean per \(minutes) min, one row per hour, columns \(header); L = below \(mmol(thresholds.low)), H = above \(mmol(thresholds.high)), - = no Reading."]
        var hour = calendar.dateInterval(of: .hour, for: viewStart)?.start ?? viewStart
        var index = 0
        while hour <= now {
            var cells: [String] = []
            for column in 0..<columns {
                let slotStart = hour.addingTimeInterval(Double(column * minutes) * 60)
                if slotStart > now { break }
                let slotEnd = slotStart.addingTimeInterval(Double(minutes) * 60)
                var values: [Double] = []
                while index < readings.count, readings[index].timestamp < slotEnd {
                    if readings[index].timestamp >= slotStart { values.append(readings[index].value) }
                    index += 1
                }
                cells.append(values.isEmpty ? "-" : flagged(values.reduce(0, +) / Double(values.count)))
            }
            lines.append("\(format(hour, "EEE HH:mm"))  \(cells.joined(separator: " "))")
            hour = hour.addingTimeInterval(3600)
        }
        return lines
    }

    private func hourlyRows() -> [String] {
        var lines = ["Hourly since \(format(detailStart, "EEE HH:mm")): mean (lowest–highest); L = a Reading below \(mmol(thresholds.low)), H = above \(mmol(thresholds.high))."]
        var hour = calendar.dateInterval(of: .hour, for: detailStart)?.start ?? detailStart
        while hour <= now {
            let next = hour.addingTimeInterval(3600)
            let values = readings.filter { $0.timestamp >= hour && $0.timestamp < next }.map(\.value)
            if let low = values.min(), let high = values.max() {
                var flags = ""
                if low < thresholds.low { flags += " L" }
                if high > thresholds.high { flags += " H" }
                lines.append("\(format(hour, "EEE HH:mm"))  \(mmol(values.reduce(0, +) / Double(values.count))) (\(mmol(low))–\(mmol(high)))\(flags)")
            } else {
                lines.append("\(format(hour, "EEE HH:mm"))  -")
            }
            hour = next
        }
        return lines
    }

    /// Days before the detail span: glucose, insulin and carbs per day, oldest first.
    private func dailyRows() -> [String] {
        guard viewStart < detailStart else { return [] }
        var lines = ["Per day before \(format(detailStart, "EEE yyyy-MM-dd")): glucose mean (lowest–highest), in range, lows; bolus, basal and carb totals."]
        var day = calendar.startOfDay(for: viewStart)
        let episodes = lowEpisodes(readings, below: thresholds.low)
        while day < detailStart {
            let next = min(calendar.date(byAdding: .day, value: 1, to: day) ?? detailStart, detailStart)
            let range = max(day, viewStart)..<next
            let values = readings.filter { range.contains($0.timestamp) }
            var parts: [String] = []
            if let low = values.map(\.value).min(), let high = values.map(\.value).max() {
                let mean = values.map(\.value).reduce(0, +) / Double(values.count)
                parts.append("\(mmol(mean)) (\(mmol(low))–\(mmol(high)))")
                if let tir = timeInRange(values, thresholds: thresholds) { parts.append("in range \(percent(tir.percent(.inRange)))") }
                parts.append("lows \(episodes.filter { range.contains($0.start) }.count)")
            } else {
                parts.append("no Readings")
            }
            let totals = insulinTotals(doses.filter { range.contains($0.timestamp) })
            parts.append("bolus \(formatUnits(totals.bolus)) u, basal \(formatUnits(totals.basal)) u")
            parts.append("carbs \(formatGrams(carbTotal(eaten.filter { range.contains($0.timestamp) }))) g")
            lines.append("\(format(day, "EEE yyyy-MM-dd"))  " + parts.joined(separator: "; "))
            day = next
        }
        return lines
    }

    private func insulin() -> String {
        var lines = ["## Insulin in view"]
        let listed = doses.filter { $0.timestamp >= detailStart }
        if doses.isEmpty {
            lines.append("No Doses recorded in view.")
        } else {
            if listed.count < doses.count {
                lines.append("Each Dose since \(format(detailStart, "EEE HH:mm")); earlier ones are in the daily totals above.")
            }
            for dose in listed {
                lines.append("- \(format(dose.timestamp, "EEE HH:mm")) \(dose.kind.rawValue) \(formatUnits(dose.units)) u\(doseSource(dose))")
            }
        }
        let totals = insulinTotals(doses)
        lines.append("Total in view: bolus \(formatUnits(totals.bolus)) u, basal \(formatUnits(totals.basal)) u.")
        if let lastBasal = doses.last(where: { $0.kind == .basal }) {
            lines.append("Last basal: \(formatUnits(lastBasal.units)) u at \(format(lastBasal.timestamp, "EEE HH:mm")).")
        }
        return lines.joined(separator: "\n")
    }

    private func food() -> String {
        var lines = ["## Food in view"]
        let listed = eaten.filter { $0.timestamp >= detailStart }
        if eaten.isEmpty {
            lines.append("No Meals logged in view.")
        } else {
            if listed.count < eaten.count {
                lines.append("Each Meal since \(format(detailStart, "EEE HH:mm")); earlier ones are in the daily totals above.")
            }
            for meal in listed {
                lines.append("- \(format(meal.timestamp, "EEE HH:mm")) \(formatGrams(meal.carbsGrams)) g carbs\(mealLabel(meal))\(macroDetail(meal))\(planDetail(meal))")
            }
        }
        lines.append("Total carbs in view: \(formatGrams(carbTotal(eaten))) g.")
        if !planned.isEmpty {
            lines.append("Planned, not eaten yet:")
            for meal in planned {
                lines.append("- \(format(meal.timestamp, "EEE HH:mm")) \(formatGrams(meal.carbsGrams)) g carbs\(mealLabel(meal))\(macroDetail(meal))\(planDetail(meal))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func planDetail(_ meal: Meal) -> String {
        guard let plan = meal.plan, plan.units > 0 else { return "" }
        var text = ", dose planned \(formatUnits(plan.units)) u, \(formatUnits(plan.takenUnits)) u logged so far"
        if let note = plan.laterNote, !note.isEmpty, plan.remainingUnits > 0 { text += ", rest: \(note)" }
        return text
    }

    private func onBoard() -> String {
        var lines = ["## On board and Forecast"]
        guard let forecast else {
            lines.append(therapy.isComplete
                ? "No Forecast right now (it needs a fresh, in-range Reading and no sensor warm-up)."
                : "No Forecast: insulin sensitivity and carb ratio are not both set.")
            return lines.joined(separator: "\n")
        }
        lines.append("Insulin on Board \(formatOneDecimal(forecast.insulinOnBoard)) u (Bolus only), Carbs on Board \(formatGrams(forecast.carbsOnBoard)) g.")
        if let anchor = forecast.points.first {
            let horizons = [30, 60, 120].compactMap { minutes -> String? in
                let target = anchor.date.addingTimeInterval(Double(minutes) * 60)
                guard let point = forecast.points.min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }),
                      abs(point.date.timeIntervalSince(target)) < forecastStep else { return nil }
                return "+\(minutes) min (\(format(point.date, "HH:mm"))) \(mmol(point.value)) (\(mmol(point.lower))–\(mmol(point.upper)))"
            }
            if !horizons.isEmpty {
                lines.append("Forecast from the latest Reading: " + horizons.joined(separator: ", ") + ".")
            }
        }
        var outlook: [String] = []
        if forecast.eventual.isFinite { outlook.append("settles around \(mmol(forecast.eventual)) once everything has acted") }
        if let low = forecast.lowCrossing { outlook.append("predicted below \(mmol(thresholds.low)) at \(format(low, "HH:mm"))") }
        if let high = forecast.highCrossing { outlook.append("predicted above \(mmol(thresholds.high)) at \(format(high, "HH:mm"))") }
        if forecast.isUncertain { outlook.append("the CGM trend and the insulin-and-carbs model disagree, so it is less certain than usual") }
        if !outlook.isEmpty { lines.append("Forecast " + outlook.joined(separator: "; ") + ".") }
        lines.append("The Forecast is the app's Loop-style model from Bolus Doses, logged Meals and the recent trend; basal is assumed to hold glucose flat.")
        if let card = forecastReview?.trackRecord, let accuracy = forecastAccuracyText(card) {
            lines.append("Forecast accuracy, last \(trackRecordDays) days (mean absolute error, bias = predicted minus actual): \(accuracy).")
        }
        return lines.joined(separator: "\n")
    }

    private func therapySection() -> String {
        let dosing = settings.dosing
        var parts: [String] = []
        parts.append(therapy.carbRatio.map { "carb ratio 1 u per \(formatTherapyNumber($0)) g" } ?? "carb ratio not set")
        parts.append(therapy.insulinSensitivity.map { "insulin sensitivity 1 u lowers \(formatTherapyNumber($0)) mmol/L" } ?? "insulin sensitivity not set")
        parts.append("target \(mmol(dosing.targetGlucose))")
        parts.append("insulin peak \(Int(therapy.insulinPeak / 60)) min, duration \(formatTherapyNumber(therapy.insulinDuration / 3600)) h")
        parts.append("carb absorption fast \(formatTherapyNumber(therapy.fastCarbAbsorptionTime / 3600)) h, normal \(formatTherapyNumber(therapy.carbAbsorptionTime / 3600)) h, slow \(formatTherapyNumber(therapy.slowCarbAbsorptionTime / 3600)) h")
        parts.append("pen step \(formatUnits(dosing.penStep)) u, max single dose \(formatUnits(dosing.maxSingleDose)) u")
        var lines = [
            "## Therapy settings",
            parts.joined(separator: "; ") + ".",
            "The app's own dose calculation: carbs ÷ carb ratio + (glucose − target) ÷ sensitivity − Insulin on Board, never below 0, rounded down to the pen step.",
        ]
        if !suggestions.isEmpty {
            lines.append("Suggestions the app has learned but the user has NOT accepted (the settings above are still in use):")
            lines += suggestions.map { "- \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    private func flagged(_ value: Double) -> String {
        if value < thresholds.low { return mmol(value) + "L" }
        if value > thresholds.high { return mmol(value) + "H" }
        return mmol(value)
    }

    private func mmol(_ value: Double) -> String { formatMmolPerL(value) }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
