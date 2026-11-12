import AppKit
import SugarbarUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let model = BarViewModel()
    private let launchAtLogin = SMAppServiceLaunchAtLogin()
    private let settingsWindow = ManagedWindow(title: "Sugarbar Settings")
    private let disclaimerWindow = ManagedWindow(title: "Welcome to Sugarbar")
    private let askClaudeWindow = ManagedWindow(title: "Ask Claude")
    private var askClaude: AskClaudeModel?
    private let mealWindow = ManagedWindow(title: "Log Meal")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ForegroundNotificationPresenter.shared.install()
        statusItemController = StatusItemController(
            model: model,
            onAskClaude: { [weak self] in self?.openAskClaude() },
            onLogMeal: { [weak self] in self?.openMealLog() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )
        observeSleepWake()
        model.start()
        if model.needsDisclaimer { showDisclaimer() }
    }

    private func openSettings() {
        settingsWindow.show {
            SettingsView(model: model, launchAtLogin: launchAtLogin)
        }
    }

    private func openAskClaude() {
        let askClaude = askClaude ?? model.makeAskClaudeModel()
        self.askClaude = askClaude
        askClaudeWindow.show {
            AskClaudeWindowContent(model: askClaude) { [weak self] in self?.openSettings() }
        }
    }

    private func openMealLog() {
        mealWindow.show {
            MealLogWindow(model: model) { [weak self] in self?.openSettings() }
        }
    }

    private func showDisclaimer() {
        disclaimerWindow.show {
            DisclaimerView { [weak self] in
                guard let self else { return }
                model.acknowledgeDisclaimer()
                disclaimerWindow.close()
                if model.accountEmail == nil { openSettings() }
            }
        }
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(systemWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemWillSleep() { model.pause() }
    @objc private func systemDidWake() { model.resume() }
}
