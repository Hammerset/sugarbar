import AppIntents

/// Opening the app already triggers an immediate poll (`RootView`'s scenePhase
/// handling), so this only needs to foreground it — no extra work in `perform()`.
struct RefreshGlucoseIntent: AppIntent {
    static var title: LocalizedStringResource { "Refresh" }
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
