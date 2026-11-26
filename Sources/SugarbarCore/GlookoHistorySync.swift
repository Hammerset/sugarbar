import Foundation

public let glookoBackfillSpan: TimeInterval = 90 * 86400
let glookoChunkSpan: TimeInterval = 7 * 86400
/// Once a day the sync re-reads this far back, so edits made in Glooko later (a pen dose marked as
/// priming, a deleted entry) reach History.
public let glookoRereadSpan: TimeInterval = 14 * 86400
public let glookoRereadInterval: TimeInterval = 86400
/// Removal stays clear of the oldest edge, in case Glooko treats its start bound as exclusive.
let glookoRemovalMargin: TimeInterval = 60

/// Always re-reads `lookback`, because a Pen can sync Doses hours after they were given.
func glookoSyncWindows(cursor: Date?, now: Date, lookback: TimeInterval = doseLookback) -> [ClosedRange<Date>] {
    let earliest = now.addingTimeInterval(-glookoBackfillSpan)
    let resume = cursor.map { $0.addingTimeInterval(-3600) } ?? earliest
    var start = max(earliest, min(resume, now.addingTimeInterval(-lookback)))
    let end = now.addingTimeInterval(60)
    var windows: [ClosedRange<Date>] = []
    while start < end {
        let chunkEnd = end.timeIntervalSince(start) < glookoChunkSpan + 3600 ? end : start.addingTimeInterval(glookoChunkSpan)
        windows.append(start...chunkEnd)
        start = chunkEnd
    }
    return windows
}

/// Advances the cursor after each window so an interrupted backfill resumes where it stopped.
/// Only when every window was fetched does it remove the Glooko Doses Glooko no longer returns,
/// and never in a window that came back without any Doses, which is more likely an error than a fact.
public func syncGlookoHistory(
    client: GlookoClient,
    store: HistoryStore,
    credentials: Credentials,
    now: Date = Date()
) async throws {
    var cursor = store.glookoCursor()
    let rereads = store.lastGlookoReread().map { now.timeIntervalSince($0) >= glookoRereadInterval || $0 > now } ?? true
    let windows = glookoSyncWindows(cursor: cursor, now: now, lookback: rereads ? glookoRereadSpan : doseLookback)
    var fetched: [InsulinDose] = []
    var complete: [ClosedRange<Date>] = []
    for window in windows {
        let history = try await client.fetchHistory(
            email: credentials.email,
            password: credentials.password,
            from: window.lowerBound,
            to: window.upperBound
        )
        store.append(readings: history.readings)
        store.append(doses: history.doses)
        fetched += history.doses
        if history.hasEveryDose, !history.doses.isEmpty { complete.append(window) }
        let settled = window.upperBound < now.addingTimeInterval(-doseLookback) ? window.upperBound : nil
        if let advanced = [cursor, history.readings.last?.timestamp, settled].compactMap(\.self).max() {
            cursor = advanced
            store.setGlookoCursor(advanced)
        }
    }
    if let oldest = windows.first?.lowerBound.addingTimeInterval(glookoRemovalMargin) {
        for window in complete where window.upperBound > oldest {
            store.removeGlookoDoses(in: max(window.lowerBound, oldest)...window.upperBound, missingFrom: fetched)
        }
    }
    if rereads { store.setLastGlookoReread(now) }
}
