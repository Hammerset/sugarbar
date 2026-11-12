import Foundation
import Testing

@testable import SugarbarCore

@Suite struct DoseReconciliationTests {
    private let t0 = Date(timeIntervalSince1970: 1_791_800_000)

    private func pen(_ units: Double, at minutes: Double, kind: InsulinKind = .bolus) -> InsulinDose {
        InsulinDose(kind: kind, units: units, timestamp: t0.addingTimeInterval(minutes * 60), insulinName: "Fiasp", deviceName: "pen")
    }

    private func manual(_ units: Double, at minutes: Double, kind: InsulinKind = .bolus) -> InsulinDose {
        .manual(kind: kind, units: units, timestamp: t0.addingTimeInterval(minutes * 60), insulinName: "Fiasp")
    }

    @Test func glookoDoseSupersedesTheManualDoseItMatches() {
        let entered = manual(4, at: 10)
        let synced = pen(4, at: -8)
        #expect(reconcileDoses([entered, synced]) == [synced])
    }

    @Test func keepsBothWhenUnitsKindOrTimeDiffer() {
        let doses = [manual(4, at: 0), pen(4.5, at: 2), manual(10, at: 60, kind: .basal), pen(10, at: 62), manual(3, at: 200), pen(3, at: 221)]
        #expect(reconcileDoses(doses).count == doses.count)
    }

    @Test func eachDoseSupersedesAtMostOnePartnerClosestFirst() {
        let early = manual(2, at: 0)
        let late = manual(2, at: 15)
        let synced = pen(2, at: 12)
        #expect(reconcileDoses([early, late, synced]) == [early, synced])

        let secondSynced = pen(2, at: -5)
        #expect(reconcileDoses([early, late, synced, secondSynced]) == [secondSynced, synced])
    }
}

@Suite struct ManualDoseStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "sugarbar-doses-\(UUID().uuidString)")
    // 31 Oct 2026 23:59:45 UTC, fifteen seconds before a month boundary.
    private let monthEnd = Date(timeIntervalSince1970: 1_793_491_185)

    @Test func editsAndDeletesSurviveReopeningAndOldLinesStillDecode() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldLine = #"{"kind":"basal","units":9,"timestamp":815181000,"insulinName":"Tresiba"}"#
        try Data((oldLine + "\n").utf8).write(to: directory.appending(path: "doses-2026-10.jsonl"))

        let store = FileHistoryStore(directory: directory)
        let first = InsulinDose.manual(kind: .bolus, units: 3, timestamp: monthEnd.addingTimeInterval(-600), insulinName: nil)
        let sameMinute = InsulinDose.manual(kind: .bolus, units: 3, timestamp: first.timestamp, insulinName: nil)
        let doomed = InsulinDose.manual(kind: .bolus, units: 1, timestamp: monthEnd.addingTimeInterval(-300), insulinName: nil)
        store.append(doses: [first, sameMinute, doomed])
        let moved = InsulinDose.manual(kind: .bolus, units: 3.5, timestamp: monthEnd.addingTimeInterval(120), insulinName: "Fiasp", entryId: first.entryId!)
        store.replace(first, with: moved)
        store.delete(dose: doomed)

        let reopened = FileHistoryStore(directory: directory)
        let all = reopened.doses(in: monthEnd.addingTimeInterval(-40 * 86400)...monthEnd.addingTimeInterval(3600))
        #expect(all.count == 3)
        #expect(all[0].origin == .glooko && all[0].kind == .basal && all[0].units == 9)
        #expect(Array(all.dropFirst()) == [sameMinute, moved])
    }

    @Test func readsAreReconciledAcrossTheIntervalEdge() {
        let store = InMemoryHistoryStore()
        let entered = InsulinDose.manual(kind: .bolus, units: 4, timestamp: monthEnd, insulinName: nil)
        let synced = InsulinDose(kind: .bolus, units: 4, timestamp: monthEnd.addingTimeInterval(-600), insulinName: nil, deviceName: "pen")
        store.append(doses: [entered, synced])
        #expect(store.doses(in: monthEnd.addingTimeInterval(-60)...monthEnd).isEmpty)
        #expect(store.doses(in: monthEnd.addingTimeInterval(-3600)...monthEnd) == [synced])
    }
}
