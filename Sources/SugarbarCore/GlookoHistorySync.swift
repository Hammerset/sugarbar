import Foundation

public let glookoBackfillSpan: TimeInterval = 90 * 86400
let glookoChunkSpan: TimeInterval = 7 * 86400

/// Always re-reads `doseLookback`, because a Pen can sync Doses hours after they were given.
func glookoSyncWindows(cursor: Date?, now: Date) -> [ClosedRange<Date>] {
    let earliest = now.addingTimeInterval(-glookoBackfillSpan)
    let resume = cursor.map { $0.addingTimeInterval(-3600) } ?? earliest
    var start = max(earliest, min(resume, now.addingTimeInterval(-doseLookback)))
    let end = now.addingTimeInterval(60)
    var windows: [ClosedRange<Date>] = []
    while start < end {
        let chunkEnd = min(start.addingTimeInterval(glookoChunkSpan), end)
        windows.append(start...chunkEnd)
        start = chunkEnd
    }
    return windows
}

/// Advances the cursor after each window so an interrupted backfill resumes where it stopped.
public func syncGlookoHistory(
    client: GlookoClient,
    store: HistoryStore,
    credentials: Credentials,
    now: Date = Date()
) async throws {
    var cursor = store.glookoCursor()
    for window in glookoSyncWindows(cursor: cursor, now: now) {
        let history = try await client.fetchHistory(
            email: credentials.email,
            password: credentials.password,
            from: window.lowerBound,
            to: window.upperBound
        )
        store.append(readings: history.readings)
        store.append(doses: history.doses)
        let settled = window.upperBound < now.addingTimeInterval(-doseLookback) ? window.upperBound : nil
        if let advanced = [cursor, history.readings.last?.timestamp, settled].compactMap(\.self).max() {
            cursor = advanced
            store.setGlookoCursor(advanced)
        }
    }
}
