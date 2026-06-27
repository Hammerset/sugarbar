import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let model = BarViewModel()
    private let launchAtLogin = SMAppServiceLaunchAtLogin()
    private let settingsWindow = ManagedWindow(title: "Sugarbar Settings")
    private let disclaimerWindow = ManagedWindow(title: "Welcome to Sugarbar")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItemController = StatusItemController(model: model) { [weak self] in
            self?.openSettings()
        }
        observeSleepWake()
        model.start()
        if model.needsDisclaimer { showDisclaimer() }
    }

    private func openSettings() {
        settingsWindow.show {
            SettingsView(model: model, launchAtLogin: launchAtLogin)
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
