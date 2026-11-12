import Foundation
import SugarbarCore
@preconcurrency import UserNotifications

/// Runs the alert policy after a poll and hands any result to Notification Center.
@MainActor
public final class GlucoseAlerter {
    private let settingsStore: SettingsStore
    private let stateStore: AlertStateStore
    private let allowsTimeSensitive: Bool

    public init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        stateStore: AlertStateStore = UserDefaultsAlertStateStore(),
        allowsTimeSensitive: Bool
    ) {
        self.settingsStore = settingsStore
        self.stateStore = stateStore
        self.allowsTimeSensitive = allowsTimeSensitive
    }

    public func evaluate(latest: Reading?, sensorActivation: Date?, forecast: Forecast?, now: Date = Date()) async {
        // Read fresh: the other device or a background launch may have changed alert settings.
        let settings = settingsStore.load()
        let state = stateStore.load()
        let conditions = glucoseAlertConditions(
            latest: latest,
            sensorActivation: sensorActivation,
            now: now,
            thresholds: settings.thresholds,
            settings: settings.alerts
        ).map {
            $0 + forecastAlertConditions(
                forecast: forecast,
                latest: latest,
                now: now,
                thresholds: settings.thresholds,
                settings: settings.alerts,
                alerting: Set(state.entries.keys)
            )
        }
        let decision = evaluateAlerts(
            conditions: conditions,
            state: state,
            now: now,
            snoozedUntil: settings.alerts.snoozedUntil
        )
        stateStore.save(decision.state)

        let center = UNUserNotificationCenter.current()
        if !decision.resolvedFamilies.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: decision.resolvedFamilies)
        }
        for notification in decision.notifications {
            do {
                try await center.add(request(for: notification))
            } catch {
                logDiagnostic("alert", error)
            }
        }
    }

    private func request(for notification: AlertNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.family
        let isLow = notification.family == GlucoseAlertFamily.low || notification.family == ForecastAlertFamily.low
        if allowsTimeSensitive, notification.isUrgent || isLow {
            content.interruptionLevel = .timeSensitive
        }
        return UNNotificationRequest(identifier: notification.family, content: content, trigger: nil)
    }

    /// Returns whether notifications are allowed; prompts only the first time.
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            logDiagnostic("notificationAuthorization", error)
            return false
        }
    }
}

/// Without a delegate the system drops notifications that arrive while the app is frontmost.
public final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    public static let shared = ForegroundNotificationPresenter()

    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
