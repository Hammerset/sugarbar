import SugarbarCore
import WidgetKit

/// Reads the App Group snapshot the app last wrote and performs no networking of its
/// own. The timeline is pre-baked with every future `BarContent` transition (live to
/// stale, warm-up to whatever follows) via `barContentSchedule`, so the widget keeps
/// ageing on its own; the app is the only thing that ever triggers a fresh timeline,
/// by calling `WidgetCenter.reloadAllTimelines()` after a successful poll.
struct GlucoseTimelineProvider: TimelineProvider {
    private let snapshotStore: GraphSnapshotStore
    private let settingsStore: SettingsStore

    init(
        snapshotStore: GraphSnapshotStore = UserDefaultsGraphSnapshotStore(),
        settingsStore: SettingsStore = UserDefaultsSettingsStore()
    ) {
        self.snapshotStore = snapshotStore
        self.settingsStore = settingsStore
    }

    func placeholder(in context: Context) -> GlucoseEntry {
        GlucoseEntry(date: Date(), content: .empty, latest: nil, history: [], thresholds: .standard)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseEntry>) -> Void) {
        let now = Date()
        let snapshot = snapshotStore.load()
        let thresholds = settingsStore.load().thresholds
        let schedule = barContentSchedule(
            latest: snapshot?.latest,
            sensorActivation: snapshot?.sensorActivation,
            now: now,
            thresholds: thresholds
        )
        let entries = schedule.map { scheduled in
            GlucoseEntry(
                date: scheduled.date,
                content: scheduled.content,
                latest: snapshot?.latest,
                history: snapshot?.history ?? [],
                thresholds: thresholds
            )
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private func currentEntry(at now: Date) -> GlucoseEntry {
        let snapshot = snapshotStore.load()
        let thresholds = settingsStore.load().thresholds
        let content = barContent(
            latest: snapshot?.latest,
            sensorActivation: snapshot?.sensorActivation,
            now: now,
            thresholds: thresholds
        )
        return GlucoseEntry(date: now, content: content, latest: snapshot?.latest, history: snapshot?.history ?? [], thresholds: thresholds)
    }
}
