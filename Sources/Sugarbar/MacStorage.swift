import AppKit
import SugarbarCore

/// The Mac's Settings and Meals stores, migrated from the App Group and gated against a wiped domain.
@MainActor
struct MacStorage {
    let settings: SettingsStore
    let meals: MealStore
    let history: HistoryStore
    let gate: StoreWriteGate

    static func prepare(defaults: UserDefaults = .sugarbarShared) -> MacStorage {
        SharedDefaultsMigration.run(
            from: defaults.persistentDomain(forName: sugarbarAppGroupIdentifier),
            into: defaults
        )
        let history = FileHistoryStore()
        let wiped = sharedDefaultsLookWiped(defaults, historyHasData: history.earliestReadingDate() != nil)
        let gate = StoreWriteGate(open: !wiped)
        return MacStorage(
            settings: GatedSettingsStore(UserDefaultsSettingsStore(defaults: defaults), gate: gate),
            meals: GatedMealStore(UserDefaultsMealStore(defaults: defaults), gate: gate),
            history: history,
            gate: gate
        )
    }

    /// Returns false when the user chose to quit rather than start from empty Settings and Meals.
    func confirmEmptyStorageIfNeeded() -> Bool {
        guard !gate.isOpen else { return true }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Settings and Meals are missing"
        alert.informativeText = """
            Sugarbar found no Settings or Meals, but your History has data, so they were probably wiped \
            or can't be read. Nothing has been saved over them. Quit to restore a backup first, or start \
            with default Settings and no Meals.
            """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Start with Defaults")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        gate.unlock()
        return true
    }
}
