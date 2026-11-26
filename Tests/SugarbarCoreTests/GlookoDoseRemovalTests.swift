import Foundation
import Testing

@testable import SugarbarCore

private let loginPageHTML = #"<html><head><meta name="csrf-token" content="tok-1" /></head><body></body></html>"#
private let dashboardHTML = """
<html><body><script>
  window.patient = "eu-west-1-patient-42";
  window.glookoConfig = { apiUrl: 'https://eu.api.glooko.com', other: 1 };
</script></body></html>
"""
private let utc = TimeZone(identifier: "UTC")!
private let pen = "Novo Nordisk NovoPen® 6/Echo Plus"

private func graphJSON(boluses: [InsulinDose], basal: String = "[]") -> String {
    let entries = boluses.map {
        #"{ "name": "Novorapid®", "timestamp": "\#(formatGlookoTimestamp($0.timestamp, timeZone: utc))", "value": \#($0.units), "deviceName": "\#(pen)" }"#
    }
    return #"{ "series": { "gkInsulinBolus": [\#(entries.joined(separator: ","))], "gkInsulinBasal": \#(basal) } }"#
}

@Suite struct GlookoDoseRemovalTests {
    private let now = Date(timeIntervalSince1970: 1_791_800_000)
    private let credentials = Credentials(email: "a@b.no", password: "pw")

    private func penDose(_ units: Double, minutesAgo: Double) -> InsulinDose {
        InsulinDose(kind: .bolus, units: units, timestamp: now.addingTimeInterval(-minutesAgo * 60), insulinName: "Novorapid®", deviceName: pen)
    }

    private func sync(_ store: HistoryStore, at date: Date, graph: [(status: Int, json: String)]) async throws {
        let transport = FakeTransport()
        await transport.stub(host: "my.glooko.com", path: "/users/sign_in", json: loginPageHTML)
        await transport.stub(host: "my.glooko.com", path: "/users/sign_in", json: dashboardHTML, url: URL(string: "https://eu.my.glooko.com/dashboard"))
        for response in graph {
            await transport.stub(host: "eu.api.glooko.com", path: "/api/v3/graph/data", status: response.status, json: response.json)
        }
        try await syncGlookoHistory(client: GlookoClient(transport: transport, timeZone: utc), store: store, credentials: credentials, now: date)
    }

    @Test func aPenDoseMarkedAsPrimingLeavesHistoryAndTheManualDoseItSupersededCountsAgain() async throws {
        let store = InMemoryHistoryStore()
        store.setGlookoCursor(now)
        store.setLastGlookoReread(now)
        let entered = InsulinDose.manual(kind: .bolus, units: 4, timestamp: now.addingTimeInterval(-30 * 60), insulinName: "Novorapid®")
        store.append(doses: [entered])
        let meal = penDose(2, minutesAgo: 180)
        let priming = penDose(4, minutesAgo: 28)

        try await sync(store, at: now, graph: [(200, graphJSON(boluses: [meal, priming]))])
        let day = now.addingTimeInterval(-86400)...now
        #expect(store.doses(in: day).map(\.units) == [2, 4])
        #expect(!store.doses(in: day).contains(entered))

        try await sync(store, at: now.addingTimeInterval(300), graph: [(200, graphJSON(boluses: [meal]))])
        #expect(store.doses(in: day) == [meal, entered])
        #expect(store.doseDeletions().map(\.id) == [priming.id])
    }

    @Test(arguments: [
        (500, "{}"),
        (200, #"{ "series": { "gkInsulinBolus": [] } }"#),
        (200, #"{ "series": { "gkInsulinBolus": [{ "timestamp": "garbled", "value": 4 }], "gkInsulinBasal": [] } }"#),
        (200, #"{ "series": { "gkInsulinBolus": [], "gkInsulinBasal": [] } }"#),
    ])
    func aFailedPartialOrEmptyReadRemovesNothing(status: Int, json: String) async throws {
        let store = InMemoryHistoryStore()
        store.setGlookoCursor(now)
        store.setLastGlookoReread(now)
        let stored = penDose(3, minutesAgo: 60)
        store.append(doses: [stored])

        try? await sync(store, at: now, graph: [(status, json)])

        #expect(store.allDoses() == [stored])
    }

    @Test func noRemovalWhenALaterWindowOfTheSameSyncFails() async throws {
        let store = InMemoryHistoryStore()
        store.setGlookoCursor(now)
        let old = penDose(3, minutesAgo: 10 * 86400 / 60)
        store.append(doses: [old])

        await #expect(throws: GlookoError.self) {
            try await sync(store, at: now, graph: [(200, graphJSON(boluses: [penDose(1, minutesAgo: 9 * 1440)])), (500, "{}")])
        }

        #expect(store.allDoses().contains(old))
        #expect(store.lastGlookoReread() == nil)
    }

    @Test func onceADayTheReadGoesBackFourteenDaysAndRemovesOlderEdits() async throws {
        let store = InMemoryHistoryStore()
        store.setGlookoCursor(now)
        store.setLastGlookoReread(now.addingTimeInterval(-3600))
        let edited = penDose(3, minutesAgo: 10 * 1440)
        let recent = penDose(2, minutesAgo: 60)
        store.append(doses: [edited, recent])
        let response = graphJSON(boluses: [recent])

        try await sync(store, at: now, graph: [(200, response)])
        #expect(store.allDoses() == [edited, recent])

        let nextDay = now.addingTimeInterval(glookoRereadInterval)
        try await sync(store, at: nextDay, graph: [(200, response)])
        #expect(store.allDoses() == [recent])
        #expect(store.lastGlookoReread() == nextDay)
    }

    @Test func deletionsSurviveReopeningAndAReturningDoseClearsItsDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sugarbar-deletions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistoryStore(directory: directory)
        let gone = penDose(4, minutesAgo: 30)
        let back = penDose(1, minutesAgo: 90)
        store.append(doses: [gone, back])
        store.removeGlookoDoses(in: now.addingTimeInterval(-86400)...now, missingFrom: [])
        store.append(doses: [back])

        let reopened = FileHistoryStore(directory: directory)
        #expect(reopened.doseDeletions() == [DoseDeletion(id: gone.id, timestamp: gone.timestamp)])
        #expect(reopened.allDoses() == [back])
    }
}
