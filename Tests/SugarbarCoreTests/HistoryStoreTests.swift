import Foundation
import Testing

@testable import SugarbarCore

@Suite struct FileHistoryStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "sugarbar-history-\(UUID().uuidString)")
    // 31 Oct 2026 23:59:45 UTC, fifteen seconds before a month boundary.
    private let monthEnd = Date(timeIntervalSince1970: 1_793_491_185)

    private func reading(_ date: Date, _ value: Double = 6.0, trend: Trend = .stable) -> Reading {
        Reading(value: value, timestamp: date, trend: trend)
    }

    @Test func deduplicatesReadingsByTimeAcrossMonthsAndPersistsThem() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(directory: directory)
        let live = reading(monthEnd, 7.1, trend: .rising)

        #expect(store.append(readings: [live, reading(monthEnd.addingTimeInterval(-300))]) == 2)
        // Same Reading from the next poll, and the Glooko copy 20 s later in the next month.
        #expect(store.append(readings: [live, reading(monthEnd.addingTimeInterval(20), 7.0, trend: .notDetermined)]) == 0)
        #expect(store.append(readings: [reading(monthEnd.addingTimeInterval(60))]) == 1)

        let reopened = FileHistoryStore(directory: directory)
        let all = reopened.readings(in: monthEnd.addingTimeInterval(-3600)...monthEnd.addingTimeInterval(3600))
        #expect(all.map(\.timestamp) == [-300, 0, 60].map { monthEnd.addingTimeInterval($0) })
        #expect(all[1] == live)
        #expect(reopened.readings(in: monthEnd.addingTimeInterval(1)...monthEnd.addingTimeInterval(3600)).count == 1)
    }

    @Test func replacesAnEditedDoseAndKeepsTheCursor() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(directory: directory)
        let dose = InsulinDose(kind: .bolus, units: 4, timestamp: monthEnd, insulinName: "Novorapid", deviceName: "pen")
        let edited = InsulinDose(kind: .bolus, units: 5, timestamp: monthEnd, insulinName: "Novorapid", deviceName: "pen")

        #expect(store.append(doses: [dose]) == 1)
        #expect(store.append(doses: [dose]) == 0)
        #expect(store.append(doses: [edited]) == 1)
        store.setGlookoCursor(monthEnd)

        let reopened = FileHistoryStore(directory: directory)
        #expect(reopened.doses(in: monthEnd.addingTimeInterval(-60)...monthEnd) == [edited])
        #expect(reopened.glookoCursor() == monthEnd)
    }
}

@Suite struct GlookoHistorySyncTests {
    private let now = Date(timeIntervalSince1970: 1_791_800_000)

    @Test func firstSyncBackfillsNinetyDaysInWeeklyWindows() {
        let windows = glookoSyncWindows(cursor: nil, now: now)
        #expect(windows.first?.lowerBound == now.addingTimeInterval(-glookoBackfillSpan))
        #expect(windows.last?.upperBound == now.addingTimeInterval(60))
        #expect(windows.count == 13)
        #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    }

    @Test func laterSyncsResumeBeforeTheCursorButAlwaysCoverTheDoseLookback() {
        let recent = glookoSyncWindows(cursor: now.addingTimeInterval(-4 * 3600), now: now)
        #expect(recent.map(\.lowerBound) == [now.addingTimeInterval(-doseLookback)])

        let stale = glookoSyncWindows(cursor: now.addingTimeInterval(-10 * 86400), now: now)
        #expect(stale.first?.lowerBound == now.addingTimeInterval(-10 * 86400 - 3600))
        #expect(stale.count == 2)
    }
}
