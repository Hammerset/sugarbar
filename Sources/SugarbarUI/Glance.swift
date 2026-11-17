import SwiftUI
import SugarbarCore

/// The current value and trend arrow in the band colour.
public struct GlucoseReadout: View {
    private let content: BarContent
    private let size: CGFloat

    public init(content: BarContent, size: CGFloat) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        HStack(alignment: .center, spacing: size * 0.18) {
            if let text = content.text {
                Text(text)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
            } else if let glyph = content.glyph {
                Image(systemName: glyph)
                    .font(.system(size: size * 0.78, weight: .semibold))
            }
            if let symbol = content.trendSymbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.58, weight: .semibold))
            }
        }
        .foregroundStyle(content.tint)
        .lineLimit(1)
    }
}

public struct ReadingAge: View {
    private let latest: Reading?

    public init(latest: Reading?) {
        self.latest = latest
    }

    public var body: some View {
        if let latest {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(formatAge(latest.age(at: context.date)))
                    .monospacedDigit()
            }
        }
    }
}

/// Insulin and Carbs on Board in one short line; nothing when both are negligible.
public struct OnBoardLine: View {
    private let forecast: Forecast?

    public init(forecast: Forecast?) {
        self.forecast = forecast
    }

    public var body: some View {
        if let forecast, forecast.insulinOnBoard >= 0.05 || forecast.carbsOnBoard >= 0.5 {
            Text("On board \(formatUnits((forecast.insulinOnBoard * 10).rounded() / 10)) u · \(formatGrams(forecast.carbsOnBoard)) g")
                .monospacedDigit()
                .accessibilityLabel("Insulin on board \(formatUnits((forecast.insulinOnBoard * 10).rounded() / 10)) units, carbs on board \(formatGrams(forecast.carbsOnBoard)) grams")
        }
    }
}

/// What the Forecast line under the chart needs to say: off for lack of Therapy Settings, or uncertain.
public struct ForecastCaption: View {
    private let forecast: Forecast?
    private let therapyComplete: Bool

    public init(forecast: Forecast?, therapyComplete: Bool) {
        self.forecast = forecast
        self.therapyComplete = therapyComplete
    }

    public var body: some View {
        if let forecast {
            if forecast.isUncertain {
                Label("Forecast uncertain: trend differs from model", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } else if !therapyComplete {
            Text("Enter Therapy Settings to see a forecast.")
                .foregroundStyle(.tertiary)
        }
    }
}

public struct AttentionItem: Identifiable, Equatable {
    public enum Tone: Equatable { case warning, neutral }

    public let id: String
    public let systemImage: String
    public let text: String
    public let tone: Tone
    public let opensMeal: Bool
}

/// Only what needs the user now: no data, a predicted low, a split dose or a planned meal that is due, a sync error.
public func attentionItems(
    content: BarContent,
    statusMessage: String?,
    forecast: Forecast?,
    latest: Reading?,
    settings: SugarbarCore.Settings,
    meals: [Meal],
    now: Date,
    syncErrors: [String]
) -> [AttentionItem] {
    var items: [AttentionItem] = []
    if let state = glucoseStateLine(content: content, statusMessage: statusMessage) {
        items.append(AttentionItem(id: "state", systemImage: state.isWarning ? "exclamationmark.triangle.fill" : "info.circle", text: state.text, tone: state.isWarning ? .warning : .neutral, opensMeal: false))
    }
    var alerts = settings.alerts
    alerts.isEnabled = true
    let lowFamilies = [ForecastAlertFamily.low, ForecastAlertFamily.fallingFast]
    for condition in forecastAlertConditions(forecast: forecast, latest: latest, now: now, thresholds: settings.thresholds, settings: alerts)
    where lowFamilies.contains(condition.family) {
        items.append(AttentionItem(id: condition.family, systemImage: "arrow.down.right.circle.fill", text: condition.title, tone: .warning, opensMeal: false))
    }
    for meal in activeMealPlans(meals, now: now) where isDue(meal, now: now) {
        items.append(AttentionItem(id: meal.id.uuidString, systemImage: meal.isPlanned ? "fork.knife" : "syringe", text: mealReminderLine(meal), tone: meal.isPlanned ? .neutral : .warning, opensMeal: true))
    }
    for (index, error) in syncErrors.enumerated() {
        items.append(AttentionItem(id: "sync\(index)", systemImage: "exclamationmark.icloud", text: error, tone: .warning, opensMeal: false))
    }
    return items
}

/// Planned meals more than 30 minutes ahead wait in the details; a split dose's remainder is always due.
public func isDue(_ meal: Meal, now: Date) -> Bool {
    !meal.isPlanned || meal.timestamp <= now.addingTimeInterval(30 * 60)
}

func mealReminderLine(_ meal: Meal) -> String {
    let time = meal.timestamp.formatted(.dateTime.hour().minute())
    if meal.isPlanned {
        return "Planned \(time): \(meal.summary), \(formatGrams(meal.carbsGrams)) g"
    }
    let remaining = meal.plan.map { formatUnits($0.remainingUnits) } ?? "0"
    let note = meal.plan?.laterNote.map { " \($0)" } ?? ""
    return "\(remaining) u still to take for \(meal.summary)\(note)"
}

public func glucoseStateLine(content: BarContent, statusMessage: String?) -> (text: String, isWarning: Bool)? {
    if let statusMessage { return (statusMessage, true) }
    switch content {
    case let .warmingUp(remaining):
        let minutes = max(1, Int(ceil(remaining / 60)))
        return ("Sensor warming up — ready in \(minutes) min", false)
    case .stale:
        return ("No Recent Data", true)
    case .empty:
        return ("Waiting for data", false)
    case let .live(_, _, _, outOfRange):
        switch outOfRange {
        case .low: return ("Below sensor range", true)
        case .high: return ("Above sensor range", true)
        case nil: return nil
        }
    }
}

public struct AttentionList: View {
    private let items: [AttentionItem]
    private let onOpenMeal: () -> Void

    public init(items: [AttentionItem], onOpenMeal: @escaping () -> Void) {
        self.items = items
        self.onOpenMeal = onOpenMeal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                if item.opensMeal {
                    Button(action: onOpenMeal) { row(item) }
                        .buttonStyle(.plain)
                } else {
                    row(item)
                }
            }
        }
    }

    private func row(_ item: AttentionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.tone == .warning ? Color.orange : Color.secondary)
            Text(item.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if item.opensMeal {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            item.tone == .warning ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: GlanceStyle.cornerRadius)
        )
        .contentShape(Rectangle())
    }
}

public enum GlanceStyle {
    public static let cornerRadius: CGFloat = 10
    public static let cardFill = Color.primary.opacity(0.05)
}

public struct QuickAction: Identifiable {
    public let id: String
    let title: String
    let systemImage: String
    let action: () -> Void

    public init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        id = title
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public static func logDose(_ action: @escaping () -> Void) -> QuickAction { QuickAction("Log Dose", systemImage: "syringe", action: action) }
    public static func logMeal(_ action: @escaping () -> Void) -> QuickAction { QuickAction("Log Meal", systemImage: "fork.knife", action: action) }
    public static func planMeal(_ action: @escaping () -> Void) -> QuickAction { QuickAction("Plan Meal", systemImage: "list.bullet.clipboard", action: action) }
    public static func askClaude(_ action: @escaping () -> Void) -> QuickAction { QuickAction("Ask Claude", systemImage: "bubble.left.and.text.bubble.right", action: action) }
}

/// The everyday actions as equal-width icon buttons with a short caption.
public struct QuickActionBar: View {
    private let actions: [QuickAction]

    public init(_ actions: [QuickAction]) {
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(actions) { item in
                Button(action: item.action) {
                    VStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 17))
                            .frame(height: 22)
                        Text(item.title)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(GlanceStyle.cardFill, in: RoundedRectangle(cornerRadius: GlanceStyle.cornerRadius))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }
}

/// Time in range, insulin and carbs for the chart's window, planned meals still ahead and pending Suggestions.
public struct GlanceDetails: View {
    private let windowLabel: String
    private let readings: [Reading]
    private let doses: [InsulinDose]
    private let meals: [Meal]
    private let upcomingMeals: [Meal]
    private let thresholds: Thresholds
    private let showsInsulin: Bool
    private let suggestions: [TherapySuggestion]
    private let onAccept: (TherapySuggestion) -> Void
    private let onDismiss: (TherapySuggestion) -> Void
    private let onOpenMeal: () -> Void

    public init(
        windowLabel: String,
        readings: [Reading],
        doses: [InsulinDose],
        meals: [Meal],
        upcomingMeals: [Meal],
        thresholds: Thresholds,
        showsInsulin: Bool,
        suggestions: [TherapySuggestion],
        onAccept: @escaping (TherapySuggestion) -> Void,
        onDismiss: @escaping (TherapySuggestion) -> Void,
        onOpenMeal: @escaping () -> Void
    ) {
        self.windowLabel = windowLabel
        self.readings = readings
        self.doses = doses
        self.meals = meals
        self.upcomingMeals = upcomingMeals
        self.thresholds = thresholds
        self.showsInsulin = showsInsulin
        self.suggestions = suggestions
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        self.onOpenMeal = onOpenMeal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("Time in range · \(windowLabel)") {
                TimeInRangeView(summary: timeInRange(readings, thresholds: thresholds))
            }
            group("Insulin and carbs · \(windowLabel)") {
                HStack(spacing: 0) {
                    if showsInsulin {
                        let totals = insulinTotals(doses)
                        stat("\(formatUnits(totals.bolus)) u", "Bolus", InsulinKind.bolus.tint)
                        stat("\(formatUnits(totals.basal)) u", "Basal", InsulinKind.basal.tint)
                    }
                    stat("\(formatGrams(carbTotal(meals))) g", "Carbs", .primary)
                }
            }
            if !upcomingMeals.isEmpty {
                group("Planned") {
                    ForEach(upcomingMeals) { meal in
                        Button(action: onOpenMeal) {
                            Text("\(meal.timestamp.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(meal.summary) · \(formatGrams(meal.carbsGrams)) g")
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !suggestions.isEmpty {
                group("Therapy suggestion") {
                    ForEach(suggestions, id: \.quantity) { suggestion in
                        TherapySuggestionRow(
                            suggestion: suggestion,
                            onAccept: { onAccept(suggestion) },
                            onDismiss: { onDismiss(suggestion) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One line standing in for the collapsed details: time in range for the window and how many Suggestions wait.
public func glanceDetailsSummary(readings: [Reading], thresholds: Thresholds, windowLabel: String, suggestionCount: Int, upcomingMealCount: Int) -> String {
    var parts: [String] = []
    if let summary = timeInRange(readings, thresholds: thresholds) {
        parts.append("\(Int(summary.percent(.inRange).rounded()))% in range · \(windowLabel)")
    } else {
        parts.append("Details · \(windowLabel)")
    }
    if upcomingMealCount > 0 { parts.append("\(upcomingMealCount) planned") }
    if suggestionCount > 0 { parts.append(suggestionCount == 1 ? "1 suggestion" : "\(suggestionCount) suggestions") }
    return parts.joined(separator: " · ")
}

public func upcomingMealPlans(_ meals: [Meal], now: Date) -> [Meal] {
    activeMealPlans(meals, now: now).filter { !isDue($0, now: now) }
}
