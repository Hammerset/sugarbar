import Foundation

public let defaultSummaryDays = 14

/// From local midnight `days - 1` days ago until `now`: the span a History Summary covers.
public func historySummaryInterval(now: Date, days: Int = defaultSummaryDays, timeZone: TimeZone = .current) -> ClosedRange<Date> {
    let calendar = summaryCalendar(timeZone)
    let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: calendar.startOfDay(for: now)) ?? now
    return start...now
}

/// A compact plain-text account of recent History for Claude: the last 24 hours at 15-minute
/// resolution with every Dose and Meal, one line per day, and a median-by-hour profile.
public func historySummary(
    readings: [Reading],
    doses: [InsulinDose],
    meals: [Meal],
    thresholds: Thresholds,
    therapy: TherapySettings,
    now: Date,
    days: Int = defaultSummaryDays,
    timeZone: TimeZone = .current
) -> String {
    let span = historySummaryInterval(now: now, days: days, timeZone: timeZone)
    let summary = SummaryBuilder(
        readings: readings.filter { span.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp },
        doses: doses.filter { span.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp },
        meals: meals.filter { span.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp },
        thresholds: thresholds,
        therapy: therapy,
        now: now,
        span: span,
        days: max(days, 1),
        timeZone: timeZone
    )
    return summary.build()
}

public func historySummary(history: HistoryStore, meals: [Meal], settings: Settings, now: Date = Date(), days: Int = defaultSummaryDays) -> String {
    let span = historySummaryInterval(now: now, days: days)
    return historySummary(
        readings: history.readings(in: span),
        doses: history.doses(in: span),
        meals: meals,
        thresholds: settings.thresholds,
        therapy: settings.therapy,
        now: now,
        days: days
    )
}

/// A run of Readings below the low threshold, merged across gaps of up to 15 minutes.
struct LowEpisode: Equatable {
    let start: Date
    let end: Date
    let nadir: Reading
}

func lowEpisodes(_ readings: [Reading], below low: Double) -> [LowEpisode] {
    var episodes: [LowEpisode] = []
    var current: (start: Date, end: Date, nadir: Reading)?
    for reading in readings where reading.value < low {
        if let open = current, reading.timestamp.timeIntervalSince(open.end) <= 15 * 60 {
            current = (open.start, reading.timestamp, reading.value < open.nadir.value ? reading : open.nadir)
        } else {
            if let open = current { episodes.append(LowEpisode(start: open.start, end: open.end, nadir: open.nadir)) }
            current = (reading.timestamp, reading.timestamp, reading)
        }
    }
    if let open = current { episodes.append(LowEpisode(start: open.start, end: open.end, nadir: open.nadir)) }
    return episodes
}

private func summaryCalendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

private struct SummaryBuilder {
    let readings: [Reading]
    let doses: [InsulinDose]
    let meals: [Meal]
    let thresholds: Thresholds
    let therapy: TherapySettings
    let now: Date
    let span: ClosedRange<Date>
    let days: Int
    let timeZone: TimeZone

    private var calendar: Calendar { summaryCalendar(timeZone) }

    func build() -> String {
        [header(), lastDay(), dailySummaries(), hourlyProfile()].joined(separator: "\n\n") + "\n"
    }

    private func header() -> String {
        let offset = timeZone.secondsFromGMT(for: now)
        let utc = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        var lines = [
            "# Glucose, insulin and meal history",
            "Generated \(format(now, "EEE yyyy-MM-dd HH:mm")). Covers the last \(days) days, from \(format(span.lowerBound, "EEE yyyy-MM-dd")).",
            "Units: glucose mmol/L, insulin units (u), carbohydrate grams (g). All times are local, time zone \(timeZone.identifier) (\(utc)).",
            "Bands: urgent low <\(mmol(thresholds.urgentLow)), low <\(mmol(thresholds.low)), in range \(mmol(thresholds.low))–\(mmol(thresholds.high)), high >\(mmol(thresholds.high)), urgent high >\(mmol(thresholds.urgentHigh)).",
            "Therapy settings: \(therapyLine()).",
            "Sources: Readings from a FreeStyle Libre 3 CGM (1-minute live, 5-minute backfill). Doses from Glooko: pen Doses only appear after the pen is synced over NFC, so recent Doses may be missing unless the user entered them in sugarbar (marked as such; Glooko's copy replaces them once synced). Meals only if the user logged them in the app. Basal Doses are long-acting insulin.",
        ]
        if let latest = readings.last {
            lines.append("Latest Reading: \(mmol(latest.value)) at \(format(latest.timestamp, "EEE HH:mm")), trend \(trendLabel(latest.trend)).")
        } else {
            lines.append("No Readings in this span.")
        }
        return lines.joined(separator: "\n")
    }

    private func therapyLine() -> String {
        var parts: [String] = []
        parts.append(therapy.insulinSensitivity.map { "insulin sensitivity \(number($0)) mmol/L per u" } ?? "insulin sensitivity not set")
        parts.append(therapy.carbRatio.map { "carb ratio \(number($0)) g per u" } ?? "carb ratio not set")
        parts.append("insulin duration \(number(therapy.insulinDuration / 3600)) h, peak \(Int(therapy.insulinPeak / 60)) min")
        parts.append("carb absorption \(number(therapy.carbAbsorptionTime / 3600)) h")
        return parts.joined(separator: "; ")
    }

    private func lastDay() -> String {
        let start = now.addingTimeInterval(-24 * 3600)
        var lines = [
            "## Last 24 hours",
            "Mean glucose per 15 minutes; each row is one hour, columns :00 :15 :30 :45 (\"-\" = no Readings).",
        ]
        var hour = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        let recent = readings.filter { $0.timestamp >= hour }
        var index = 0
        while hour <= now {
            var cells: [String] = []
            for quarter in 0..<4 {
                let slotStart = hour.addingTimeInterval(Double(quarter) * 900)
                let slotEnd = slotStart.addingTimeInterval(900)
                if slotStart > now { break }
                var values: [Double] = []
                while index < recent.count, recent[index].timestamp < slotEnd {
                    if recent[index].timestamp >= slotStart { values.append(recent[index].value) }
                    index += 1
                }
                cells.append(values.isEmpty ? "-" : mmol(values.reduce(0, +) / Double(values.count)))
            }
            lines.append("\(format(hour, "EEE HH:mm"))  \(cells.joined(separator: " "))")
            hour = hour.addingTimeInterval(3600)
        }

        var events: [(Date, String)] = []
        for dose in doses where dose.timestamp >= start {
            events.append((dose.timestamp, "\(dose.kind.rawValue) \(formatUnits(dose.units)) u\(doseSource(dose))"))
        }
        for meal in meals where meal.timestamp >= start {
            events.append((meal.timestamp, "meal \(formatGrams(meal.carbsGrams)) g carbs\(mealLabel(meal))"))
        }
        for episode in lowEpisodes(readings.filter { $0.timestamp >= start }, below: thresholds.low) {
            events.append((episode.start, "low until \(format(episode.end, "HH:mm")), lowest \(mmol(episode.nadir.value)) at \(format(episode.nadir.timestamp, "HH:mm"))"))
        }
        lines.append("Events (Doses, Meals, lows):")
        if events.isEmpty {
            lines.append("- none recorded")
        } else {
            for (date, text) in events.sorted(by: { $0.0 < $1.0 }) {
                lines.append("- \(format(date, "EEE HH:mm")) \(text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func dailySummaries() -> String {
        var lines = [
            "## Daily summaries (oldest first)",
            "Time in Range per Band; coverage = share of 5-minute slots with a Reading.",
        ]
        let episodes = lowEpisodes(readings, below: thresholds.low)
        var day = span.lowerBound
        while day <= now {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? now
            let range = day..<next
            lines.append(dayLine(
                day: day,
                end: min(next, now),
                readings: readings.filter { range.contains($0.timestamp) },
                doses: doses.filter { range.contains($0.timestamp) },
                meals: meals.filter { range.contains($0.timestamp) },
                lows: episodes.filter { range.contains($0.start) }
            ))
            day = next
        }
        return lines.joined(separator: "\n")
    }

    private func dayLine(day: Date, end: Date, readings: [Reading], doses: [InsulinDose], meals: [Meal], lows: [LowEpisode]) -> String {
        var parts: [String] = []
        if let tir = timeInRange(readings, thresholds: thresholds),
           let low = readings.min(by: { $0.value < $1.value }),
           let high = readings.max(by: { $0.value < $1.value }) {
            let mean = readings.map(\.value).reduce(0, +) / Double(readings.count)
            let slots = Set(readings.map { Int($0.timestamp.timeIntervalSince1970 / timeInRangeSlot) }).count
            let possible = max(1, Int(ceil(end.timeIntervalSince(day) / timeInRangeSlot)))
            parts.append("mean \(mmol(mean)), min \(mmol(low.value)) at \(format(low.timestamp, "HH:mm")), max \(mmol(high.value)) at \(format(high.timestamp, "HH:mm"))")
            parts.append("TIR urgent low \(percent(tir.percent(.urgentLow))), low \(percent(tir.percent(.low))), in range \(percent(tir.percent(.inRange))), high \(percent(tir.percent(.high))), urgent high \(percent(tir.percent(.urgentHigh)))")
            parts.append("coverage \(percent(min(100, Double(slots) / Double(possible) * 100)))")
        } else {
            parts.append("no Readings")
        }
        if lows.isEmpty {
            parts.append("lows 0")
        } else {
            let detail = lows.map { "\(format($0.start, "HH:mm")) (lowest \(mmol($0.nadir.value)))" }.joined(separator: ", ")
            parts.append("lows \(lows.count): \(detail)")
        }
        let totals = insulinTotals(doses)
        let boluses = doses.filter { $0.kind == .bolus }
        var insulin = "bolus \(formatUnits(totals.bolus)) u"
        if !boluses.isEmpty {
            insulin += " (" + boluses.map { "\(format($0.timestamp, "HH:mm")) \(formatUnits($0.units))\($0.isManual ? " entered in sugarbar" : "")" }.joined(separator: ", ") + ")"
        }
        insulin += ", basal \(formatUnits(totals.basal)) u"
        parts.append(insulin)
        var carbs = "carbs \(formatGrams(carbTotal(meals))) g"
        if !meals.isEmpty {
            carbs += " (" + meals.map { "\(format($0.timestamp, "HH:mm")) \(formatGrams($0.carbsGrams)) g\(mealLabel($0))" }.joined(separator: ", ") + ")"
        }
        parts.append(carbs)
        return "- \(format(day, "EEE yyyy-MM-dd")): " + parts.joined(separator: "; ")
    }

    private func hourlyProfile() -> String {
        var lines = [
            "## Time-of-day profile (all \(days) days)",
            "Hour: median glucose (10th–90th percentile), share of Readings below \(mmol(thresholds.low)), days with data.",
        ]
        var byHour: [Int: [Reading]] = [:]
        for reading in readings {
            byHour[calendar.component(.hour, from: reading.timestamp), default: []].append(reading)
        }
        for hour in 0..<24 {
            let label = String(format: "%02d", hour)
            guard let members = byHour[hour], !members.isEmpty else {
                lines.append("\(label): no data")
                continue
            }
            let values = members.map(\.value).sorted()
            let low = Double(values.filter { $0 < thresholds.low }.count) / Double(values.count) * 100
            let daysWithData = Set(members.map { calendar.startOfDay(for: $0.timestamp) }).count
            lines.append("\(label): \(mmol(quantile(values, 0.5))) (\(mmol(quantile(values, 0.1)))–\(mmol(quantile(values, 0.9)))), low \(percent(low)), \(daysWithData) d")
        }
        return lines.joined(separator: "\n")
    }

    private func doseSource(_ dose: InsulinDose) -> String {
        let source = dose.isManual ? "entered in sugarbar, pen not yet synced" : dose.isFromPen ? "pen" : "typed into Glooko"
        if let name = dose.insulinName, !name.isEmpty { return " (\(name), \(source))" }
        return " (\(source))"
    }

    private func mealLabel(_ meal: Meal) -> String {
        let summary = meal.summary
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !summary.isEmpty else { return "" }
        return " \"\(summary.count > 60 ? String(summary.prefix(57)) + "..." : summary)\""
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private func quantile(_ sorted: [Double], _ q: Double) -> Double {
    let position = q * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
}

private func mmol(_ value: Double) -> String { formatMmolPerL(value) }

private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

private func number(_ value: Double) -> String {
    value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

private func trendLabel(_ trend: Trend) -> String {
    switch trend {
    case .notDetermined: "not known"
    case .fallingQuickly: "falling quickly"
    case .falling: "falling"
    case .stable: "stable"
    case .rising: "rising"
    case .risingQuickly: "rising quickly"
    }
}
