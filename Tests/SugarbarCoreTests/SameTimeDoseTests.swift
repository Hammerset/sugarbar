import Foundation
import Testing

@testable import SugarbarCore

private let oslo = TimeZone(identifier: "Europe/Oslo")!
private let pen = "Novo Nordisk NovoPen® 6/Echo Plus"
// 2026-10-12 16:40:00 Oslo (UTC+2).
private let t1640 = Date(timeIntervalSince1970: 1_791_816_000)

private func glookoResponse(_ boluses: [Double]) -> Data {
    let entries = boluses.map {
        #"{ "name": "Novorapid®", "timestamp": "2026-10-12T16:40:00.000Z", "value": \#($0), "deviceName": "\#(pen)" }"#
    }
    return Data(#"{ "series": { "gkInsulinBolus": [\#(entries.joined(separator: ","))] } }"#.utf8)
}

private func fetched(_ boluses: [Double]) throws -> [InsulinDose] {
    try decodeGlookoHistory(glookoResponse(boluses), timeZone: oslo).doses
}

@Suite struct SameTimeDoseTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "sugarbar-history-\(UUID().uuidString)")
    private let window = t1640.addingTimeInterval(-3600)...t1640.addingTimeInterval(3600)

    @Test func twoPenDosesAtTheSameSecondBothCountInInsulinOnBoard() throws {
        let store = InMemoryHistoryStore()
        store.append(doses: try fetched([3, 2.5]))

        let doses = store.doses(in: window)
        #expect(doses.map(\.units).sorted() == [2.5, 3])
        let now = t1640.addingTimeInterval(35 * 60)
        let readings = [Reading(value: 9, timestamp: now, trend: .notDetermined)]
        let result = try #require(forecast(
            readings: readings, doses: doses, meals: [], therapy: TherapySettings(insulinSensitivity: 2.5, carbRatio: 10),
            thresholds: .standard, sensorActivation: nil, now: now
        ))
        let model = ExponentialInsulinModel(peak: 75 * 60, duration: 6 * 3600)
        #expect(abs(result.insulinOnBoard - 5.5 * model.remainingFraction(after: 35 * 60)) < 1e-9)
    }

    @Test func aReFetchReplacesInsteadOfDuplicating() throws {
        let store = InMemoryHistoryStore()
        #expect(store.append(doses: try fetched([3, 2.5])) == 2)
        #expect(store.append(doses: try fetched([2.5, 3])) == 0)

        // Units corrected in Glooko: still two Doses, now with the new amount.
        store.append(doses: try fetched([3, 4]))
        #expect(store.doses(in: window).map(\.units).sorted() == [3, 4])
    }

    @Test func historyWrittenBeforeNumberingTakesTheSecondDoseWithoutDuplicates() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The old id kept only the last of the pair: here the 3 u.
        let oldLine = #"{"kind":"bolus","timestamp":\#(t1640.timeIntervalSinceReferenceDate),"origin":"glooko","units":3,"insulinName":"Novorapid®","deviceName":"\#(pen)"}"#
        try Data((oldLine + "\n").utf8).write(to: directory.appending(path: "doses-\(MonthKey(t1640)).jsonl"))

        let store = FileHistoryStore(directory: directory)
        #expect(store.doses(in: window).map(\.units) == [3])
        store.append(doses: try fetched([3, 2.5]))
        store.append(doses: try fetched([3, 2.5]))

        let reopened = FileHistoryStore(directory: directory)
        #expect(reopened.allDoses().map(\.units).sorted() == [2.5, 3])
        #expect(Set(reopened.allDoses().map(\.id)).count == 2)
    }

    @Test func aManualDoseIsSupersededByOnlyOneOfAPair() throws {
        let store = InMemoryHistoryStore()
        store.append(doses: [.manual(kind: .bolus, units: 3, timestamp: t1640.addingTimeInterval(120), insulinName: nil)])
        store.append(doses: try fetched([3, 3]))

        let doses = store.doses(in: window)
        #expect(doses.count == 2 && doses.allSatisfy { !$0.isManual })
    }
}

@MainActor
@Suite struct SameTimeDoseSyncTests {
    private let clock = TestClock(t1640.addingTimeInterval(3600))
    private let server = FakeSyncServer()

    @Test func devicesWithTheOldAndTheNewIdsConvergeWithoutDuplicates() async throws {
        let mac = SimulatedDevice(server: server, clock: clock)
        let phone = SimulatedDevice(server: server, clock: clock)
        let survivor = InsulinDose(kind: .bolus, units: 3, timestamp: t1640, insulinName: "Novorapid®", deviceName: pen)
        mac.history.append(doses: [survivor])
        try await mac.sync()

        phone.history.append(doses: try fetched([3, 2.5]))
        try await phone.sync()
        try await mac.sync()
        try await phone.sync()

        let expected = phone.history.allDoses()
        #expect(expected.map(\.units).sorted() == [2.5, 3])
        #expect(mac.history.allDoses() == expected)
        #expect(server.storedDoses.count == 2)
    }

    @Test func aDoseAloneAtItsTimeKeepsItsOldIdAndPayloadSoItsMonthIsNotUploadedAgain() throws {
        let dose = try #require(try fetched([3]).first)
        let legacy = InsulinDose(kind: .bolus, units: 3, timestamp: t1640, insulinName: "Novorapid®", deviceName: pen)
        #expect(try WireDose(dose) == WireDose(legacy))
        #expect(dose.id == "bolus-\(t1640.timeIntervalSince1970)")
    }
}
