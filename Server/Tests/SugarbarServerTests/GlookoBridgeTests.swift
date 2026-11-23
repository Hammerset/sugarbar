import Foundation
import HummingbirdTesting
import Logging
import PostgresNIO
import Synchronization
import Testing
@testable import SugarbarServer

final class TestClock: Sendable {
    private let value = Mutex(Date())
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

struct BridgeAccount {
    let id: Int64
    let token: String
    /// Starts a new bridge, as after a server restart: nothing it kept in memory survives.
    let restart: @Sendable () -> Void
}

let oslo = GlookoWallClock(timeZone: TimeZone(identifier: "Europe/Oslo")!)

/// One account with Send to Glooko on, a bridge for it pointed at `fake`, and a sync client.
func withBridge(
    _ fake: FakeGlooko,
    clock: TestClock = TestClock(),
    password: String = FakeGlooko.password,
    _ body: @Sendable @escaping (_ run: @Sendable () async throws -> Void, BridgeAccount, any TestClientProtocol) async throws -> Void
) async throws {
    let name = "glooko-\(UUID().uuidString)"
    let output = try await AdminCommand.createAccount(name: name).run(ServerConfiguration(databaseURL: testDatabaseURL), logger: testLogger)
    let token = String(output.split(separator: "\n").last!)
    let credentials = FileManager.default.temporaryDirectory.appending(path: "glooko-\(UUID().uuidString).json").path
    try GlookoCredentialsFile(path: credentials).set(account: name, credentials: GlookoCredentials(email: FakeGlooko.email, password: password))
    defer { try? FileManager.default.removeItem(atPath: credentials) }

    try await withFakeGlooko(fake) { signInURL in
        let db = PostgresClient(configuration: try postgresConfiguration(url: testDatabaseURL), backgroundLogger: testLogger)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await db.run() }
            defer { group.cancelAll() }
            var accountId: Int64 = 0
            for try await id in try await db.query("SELECT account_id FROM tokens WHERE token_hash = \(Tokens.hash(token))").decode(Int64.self) {
                accountId = id
            }
            let configuration = GlookoBridgeConfiguration(credentialsFile: credentials, signInURL: signInURL, readInterval: 0)
            let http = makeGlookoHTTPClient()
            let makeBridge: @Sendable () -> GlookoBridge = { GlookoBridge(db: db, configuration: configuration, http: http, logger: testLogger, now: { clock.now }) }
            let bridge = Mutex(makeBridge())
            let id = accountId
            let account = BridgeAccount(id: accountId, token: token, restart: { bridge.withLock { $0 = makeBridge() } })
            do {
                let run: @Sendable () async throws -> Void = {
                    try await bridge.withLock { $0 }.tick(onlyAccount: id)
                }
                try await withServer { client in
                    _ = try await client.sync(token: token, changes: [settings(enabled: true, at: clock.now)])
                    try await run()
                    try await body(run, account, client)
                }
            } catch {
                try await http.shutdown()
                throw error
            }
            try await http.shutdown()
        }
    }
}

func settings(enabled: Bool, at date: Date) -> Change {
    Change(kind: "glookoSettings", id: "default", updatedAt: Timestamps.format(date), payload: .object([
        "enabled": .bool(enabled), "timeZone": .string("Europe/Oslo"),
    ]))
}

func meal(_ id: UUID, carbs: Double, summary: String, at eaten: Date, state: String = "eaten", updated: Date) -> Change {
    Change(kind: "meal", id: id.uuidString, updatedAt: Timestamps.format(updated), payload: .object([
        "id": .string(id.uuidString), "timestamp": .double(eaten.timeIntervalSinceReferenceDate),
        "carbsGrams": .double(carbs), "summary": .string(summary), "state": .string(state),
    ]))
}

func manualDose(_ entry: UUID, kind: String, units: Double, at taken: Date, updated: Date) -> Change {
    Change(kind: "manualDose", id: "manual-\(entry.uuidString)", updatedAt: Timestamps.format(updated), payload: .object([
        "kind": .string(kind), "units": .double(units), "timestamp": .double(taken.timeIntervalSinceReferenceDate),
        "insulinName": .string(kind == "bolus" ? "Novorapid" : "Tresiba"), "origin": .string("manual"), "entryId": .string(entry.uuidString),
    ]))
}

extension TestClientProtocol {
    func record(_ kind: String, _ id: String, token: String) async throws -> Change? {
        try await syncAll(token: token).last { $0.kind == kind && $0.id == id }
    }

    func status(_ sourceKind: String, _ id: String, token: String) async throws -> [String: JSONValue]? {
        guard case .object(let fields)? = try await record("glookoStatus", "\(sourceKind)/\(id)", token: token)?.payload else { return nil }
        return fields
    }
}

@Suite(.serialized) struct GlookoBridgeTests {
    @Test func eatenMealsAreCreatedEditedAndDeletedInGlooko() async throws {
        let fake = FakeGlooko()
        let clock = TestClock()
        try await withBridge(fake, clock: clock) { run, account, client in
            let id = UUID(), planned = UUID()
            let eaten = clock.now.addingTimeInterval(-3600)
            _ = try await client.sync(token: account.token, changes: [
                meal(id, carbs: 40, summary: "Pasta", at: eaten, updated: clock.now),
                meal(planned, carbs: 70, summary: "Pizza later", at: clock.now, state: "planned", updated: clock.now),
            ])
            try await run()
            var foods = await fake.liveFoods
            #expect(foods.count == 1)
            #expect(foods.first?["guid"] == .string(GlookoItems.guid(for: "meal", id: id.uuidString)))
            #expect(foods.first?["carbs"]?.doubleValue == 40)
            #expect(foods.first?["name"] == .string("Pasta"))
            #expect(foods.first?["timestamp"] == .string(oslo.format(eaten)))
            #expect(try await client.status("meal", id.uuidString, token: account.token)?["state"] == .string("sent"))

            clock.advance(60)
            _ = try await client.sync(token: account.token, changes: [meal(id, carbs: 55, summary: "Pasta", at: eaten, updated: clock.now)])
            try await run()
            foods = await fake.liveFoods
            #expect(foods.count == 1)
            #expect(foods.first?["carbs"]?.doubleValue == 55)

            clock.advance(60)
            _ = try await client.sync(token: account.token, changes: [Change(id: id.uuidString, updatedAt: Timestamps.format(clock.now), deleted: true, payload: nil)])
            try await run()
            #expect(await fake.liveFoods.isEmpty)
            #expect(await fake.foods.count == 1)
            #expect(try await client.status("meal", id.uuidString, token: account.token)?["state"] == .string("deleted"))
        }
    }

    @Test func aRetryAfterACrashOverwritesTheSameEntry() async throws {
        let fake = FakeGlooko()
        let clock = TestClock()
        try await withBridge(fake, clock: clock) { run, account, client in
            let id = UUID()
            await fake.configure { $0.failAfterNextWrite = true }
            _ = try await client.sync(token: account.token, changes: [meal(id, carbs: 30, summary: "Toast", at: clock.now, updated: clock.now)])
            try await run()
            #expect(try await client.status("meal", id.uuidString, token: account.token)?["state"] == .string("waiting"))

            clock.advance(120)
            account.restart()
            try await run()
            #expect(await fake.puts == 2)
            #expect(await fake.foods.count == 1)
            #expect(try await client.status("meal", id.uuidString, token: account.token)?["state"] == .string("sent"))
        }
    }

    @Test func aPenDoseRemovesTheClosestMatchingManualDoseOnce() async throws {
        let fake = FakeGlooko()
        let clock = TestClock()
        try await withBridge(fake, clock: clock) { run, account, client in
            let first = UUID(), second = UUID(), basal = UUID()
            let taken = clock.now.addingTimeInterval(-1800)
            _ = try await client.sync(token: account.token, changes: [
                manualDose(first, kind: "bolus", units: 4, at: taken, updated: clock.now),
                manualDose(second, kind: "bolus", units: 4, at: taken.addingTimeInterval(600), updated: clock.now),
                manualDose(basal, kind: "basal", units: 4, at: taken, updated: clock.now),
            ])
            try await run()
            #expect(await fake.liveInsulins.count == 3)
            let firstStatus = try await client.status("manualDose", "manual-\(first.uuidString)", token: account.token)
            #expect(firstStatus?["state"] == .string("sent"))
            #expect(firstStatus?["echoes"] == .array([.object(["kind": .string("bolus"), "units": .int(4), "t": .int(Int64(taken.timeIntervalSince1970))])]))

            await fake.configure { $0.penDoses = [("bolus", oslo.format(taken.addingTimeInterval(120)), 4)] }
            clock.advance(60)
            try await run()
            let live = await fake.liveInsulins
            #expect(live.count == 2)
            #expect(!live.contains { $0["guid"] == .string(GlookoItems.guid(for: "manualDose", id: "manual-\(first.uuidString)")) })
            let removed = try await client.status("manualDose", "manual-\(first.uuidString)", token: account.token)
            #expect(removed?["state"] == .string("removed"))
            #expect(removed?["message"]?.stringValue?.contains("Pen dose of 4 U") == true)
            #expect(try await client.status("manualDose", "manual-\(second.uuidString)", token: account.token)?["state"] == .string("sent"))

            clock.advance(60)
            try await run()
            #expect(await fake.liveInsulins.count == 2)
        }
    }

    @Test func carbsEnteredInGlookoBecomeMealsAndOurOwnAreNotImported() async throws {
        let fake = FakeGlooko()
        let clock = TestClock()
        try await withBridge(fake, clock: clock) { run, account, client in
            let ours = UUID()
            _ = try await client.sync(token: account.token, changes: [meal(ours, carbs: 20, summary: "Yoghurt", at: clock.now, updated: clock.now)])
            await fake.addAppFood(guid: "APP-FOOD-1", timestamp: oslo.format(clock.now.addingTimeInterval(-900)), name: "Banana", carbs: 25)
            try await run()
            clock.advance(60)
            try await run()

            func meals() async throws -> [Change] {
                try await client.syncAll(token: account.token).filter { $0.kind == "meal" && !$0.deleted }
            }
            var all = try await meals()
            #expect(all.count == 2)
            let imported = try #require(all.first { $0.id != ours.uuidString })
            #expect(imported.id != "APP-FOOD-1")
            guard case .object(let payload)? = imported.payload else { Issue.record("no payload"); return }
            #expect(payload["carbsGrams"]?.doubleValue == 25)
            #expect(payload["summary"] == .string("Banana"))
            #expect(try await client.status("meal", imported.id, token: account.token)?["state"] == .string("imported"))
            #expect(await fake.puts == 1)
            #expect(await fake.foods.count == 2)

            await fake.addAppFood(guid: "APP-FOOD-1", timestamp: oslo.format(clock.now.addingTimeInterval(-900)), name: "Banana", carbs: 30)
            clock.advance(60)
            try await run()
            all = try await meals()
            guard case .object(let edited)? = all.first(where: { $0.id == imported.id })?.payload else { Issue.record("edit lost"); return }
            #expect(edited["carbsGrams"]?.doubleValue == 30)

            await fake.addAppFood(guid: "APP-FOOD-1", timestamp: oslo.format(clock.now.addingTimeInterval(-900)), name: "Banana", carbs: 30, deleted: true)
            clock.advance(60)
            try await run()
            #expect(try await meals().map(\.id) == [ours.uuidString])
            #expect(await fake.puts == 1)
        }
    }

    @Test func anExpiredSessionSignsInAgain() async throws {
        let fake = FakeGlooko()
        let clock = TestClock()
        try await withBridge(fake, clock: clock) { run, account, client in
            let id = UUID()
            _ = try await client.sync(token: account.token, changes: [meal(id, carbs: 10, summary: "Apple", at: clock.now, updated: clock.now)])
            try await run()
            #expect(await fake.signIns == 1)
            await fake.configure { $0.expireNextCall = true }
            clock.advance(60)
            _ = try await client.sync(token: account.token, changes: [meal(id, carbs: 12, summary: "Apple", at: clock.now, updated: clock.now)])
            try await run()
            #expect(await fake.signIns == 2)
            #expect(await fake.liveFoods.first?["carbs"]?.doubleValue == 12)
            #expect(try await client.status("meal", id.uuidString, token: account.token)?["state"] == .string("sent"))
        }
    }

    @Test func aWrongPasswordIsNotRetriedRightAway() async throws {
        let fake = FakeGlooko()
        let clock = TestClock()
        try await withBridge(fake, clock: clock, password: "wrong") { run, account, client in
            _ = try await client.sync(token: account.token, changes: [meal(UUID(), carbs: 10, summary: "Apple", at: clock.now, updated: clock.now)])
            clock.advance(60)
            try await run()
            guard case .object(let summary)? = try await client.record("glookoBridge", "status", token: account.token)?.payload else {
                Issue.record("no summary"); return
            }
            #expect(summary["state"] == .string("signInFailed"))
            #expect(await fake.signInAttempts == 1)
            #expect(await fake.foods.isEmpty)
        }
    }

    @Test func anUnexpectedAnswerPausesSendingUntilTheToggleChanges() async throws {
        let fake = FakeGlooko()
        let clock = TestClock()
        try await withBridge(fake, clock: clock) { run, account, client in
            let id = UUID()
            await fake.configure { $0.writeOverride = (200, #"{"something":"new"}"#) }
            _ = try await client.sync(token: account.token, changes: [meal(id, carbs: 15, summary: "Crackers", at: clock.now, updated: clock.now)])
            try await run()
            clock.advance(3600)
            try await run()
            #expect(await fake.puts == 1)
            guard case .object(let summary)? = try await client.record("glookoBridge", "status", token: account.token)?.payload else {
                Issue.record("no summary"); return
            }
            #expect(summary["state"] == .string("paused"))

            await fake.configure { $0.writeOverride = (403, "") }
            clock.advance(60)
            _ = try await client.sync(token: account.token, changes: [settings(enabled: true, at: clock.now)])
            try await run()
            clock.advance(3600)
            try await run()
            #expect(await fake.puts == 2)

            await fake.configure { $0.writeOverride = nil }
            clock.advance(60)
            _ = try await client.sync(token: account.token, changes: [settings(enabled: true, at: clock.now)])
            try await run()
            #expect(await fake.liveFoods.count == 1)
            #expect(try await client.status("meal", id.uuidString, token: account.token)?["state"] == .string("sent"))
        }
    }

    @Test func aRejectedItemFailsWithoutRetryingWhileOthersGoOn() async throws {
        let fake = FakeGlooko()
        let clock = TestClock()
        try await withBridge(fake, clock: clock) { run, account, client in
            let id = UUID()
            await fake.configure { $0.writeOverride = (422, #"{"foods":[{"errors":{"carbs":["is invalid"]}}]}"#) }
            _ = try await client.sync(token: account.token, changes: [meal(id, carbs: 15, summary: "Crackers", at: clock.now, updated: clock.now)])
            try await run()
            clock.advance(3600)
            try await run()
            #expect(await fake.puts == 1)
            let status = try await client.status("meal", id.uuidString, token: account.token)
            #expect(status?["state"] == .string("failed"))
            #expect(status?["message"] == .string("Glooko rejected it: invalid carbs"))
        }
    }

    @Test func wallClockFollowsDaylightSavingAtTheEntrysOwnDate() {
        let beforeSwitch = Date(timeIntervalSince1970: 1_774_744_200)
        #expect(oslo.format(beforeSwitch) == "2026-03-29T01:30:00.000Z")
        #expect(oslo.format(beforeSwitch.addingTimeInterval(3600)) == "2026-03-29T03:30:00.000Z")
        #expect(oslo.parse("2026-03-29T03:30:00.000Z") == beforeSwitch.addingTimeInterval(3600))
        #expect(oslo.parse("2026-07-01T12:00:00.000Z") == Date(timeIntervalSince1970: 1_782_900_000))
    }
}
