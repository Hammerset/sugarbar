import SwiftUI
import SugarbarCore

public struct AlertSettingsRows: View {
    @Binding private var settings: AlertSettings
    @State private var notificationsDenied = false

    public init(settings: Binding<AlertSettings>) {
        _settings = settings
    }

    public static let footer = "Sugarbar is not a medical device. Alerts only fire when a fresh Reading arrives, so they can be late or missed if the device sleeps, goes offline or LibreLinkUp lags. Keep your sensor app's own alarms on."

    public var body: some View {
        Toggle("Low/high alerts", isOn: $settings.isEnabled)
            .onChange(of: settings.isEnabled) { _, isOn in
                guard isOn else { return }
                Task { notificationsDenied = await !GlucoseAlerter.requestAuthorization() }
            }
        if notificationsDenied {
            Text("Notifications are turned off for Sugarbar. Allow them in System Settings → Notifications.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if settings.isEnabled {
            ForEach(AlertLevel.allCases, id: \.self) { level in
                Toggle(level.label, isOn: levelBinding(level))
            }
            Stepper(
                "Repeat lows every \(minutes(settings.lowRepeatInterval)) min",
                value: minutesBinding(\.lowRepeatInterval),
                in: minuteRange,
                step: 5
            )
            Stepper(
                "Repeat highs every \(minutes(settings.highRepeatInterval)) min",
                value: minutesBinding(\.highRepeatInterval),
                in: minuteRange,
                step: 5
            )
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let until = settings.snoozedUntil, until > context.date {
                    LabeledContent("Snoozed until", value: until.formatted(date: .omitted, time: .shortened))
                    Button("Resume Alerts") { settings.snoozedUntil = nil }
                } else {
                    Button("Snooze for 1 Hour") { settings.snoozedUntil = Date().addingTimeInterval(60 * 60) }
                }
            }
        }
    }

    private var minuteRange: ClosedRange<Int> {
        minutes(AlertSettings.repeatIntervalRange.lowerBound)...minutes(AlertSettings.repeatIntervalRange.upperBound)
    }

    private func minutes(_ interval: TimeInterval) -> Int {
        Int(interval / 60)
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<AlertSettings, TimeInterval>) -> Binding<Int> {
        Binding(
            get: { minutes(settings[keyPath: keyPath]) },
            set: { settings[keyPath: keyPath] = TimeInterval($0 * 60) }
        )
    }

    private func levelBinding(_ level: AlertLevel) -> Binding<Bool> {
        Binding(
            get: { settings.enabledLevels.contains(level) },
            set: { isOn in
                if isOn {
                    settings.enabledLevels.insert(level)
                } else {
                    settings.enabledLevels.remove(level)
                }
            }
        )
    }
}
