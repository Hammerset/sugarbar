import Foundation
import Testing

@testable import SugarbarCore

@MainActor
@Suite struct SyncEngineTests {
    private let clock = TestClock(Date(timeIntervalSince1970: 1_790_000_000))
    private let server = FakeSyncServer()

    private func device() -> SimulatedDevice { SimulatedDevice(server: server, clock: clock) }

    private func meal(_ summary: String, carbs: Double = 40, minutesAgo: Double = 30, id: UUID = UUID()) -> Meal {
        Meal(id: id, timestamp: clock.now.addingTimeInterval(-minutesAgo * 60), carbsGrams: carbs, summary: summary)
    }

    private func edited(_ meal: Meal, carbs: Double) -> Meal {
        Meal(id: meal.id, timestamp: meal.timestamp, carbsGrams: carbs, summary: meal.summary)
    }

    @Test func doesNothingWithoutConfiguration() async throws {
        let phone = device()
        phone.isConfigured = false
        phone.meals.upsert(meal("toast"))
        phone.engine.recordLocalChanges()
        try await phone.sync()

        #expect(server.requests.isEmpty)
        #expect(phone.stateStore.load() == nil)
    }

    @Test func twoDevicesConvergeAfterEditsAndDeletes() async throws {
        let phone = device()
        let mac = device()
        let pasta = meal("pasta")
        let dose = InsulinDose.manual(kind: .bolus, units: 4, timestamp: clock.now.addingTimeInterval(-600), insulinName: "Fiasp")
        phone.meals.upsert(pasta)
        phone.history.append(doses: [dose])

        try await phone.sync()
        try await mac.sync()
        #expect(mac.meals.load() == [pasta])
        #expect(mac.history.allDoses() == [dose])
        #expect(mac.applied.contains { $0.meals == [pasta.id] })

        clock.advance(60)
        mac.meals.upsert(edited(pasta, carbs: 55))
        mac.history.delete(dose: dose)
        try await mac.sync()
        try await phone.sync()

        #expect(phone.meals.load().map(\.carbsGrams) == [55])
        #expect(phone.history.allDoses().isEmpty)
        #expect(phone.meals.load() == mac.meals.load())
    }

    @Test(arguments: [true, false])
    func laterEditWinsWhicheverDeviceSyncsFirst(phoneFirst: Bool) async throws {
        let phone = device()
        let mac = device()
        let pasta = meal("pasta")
        phone.meals.upsert(pasta)
        try await phone.sync()
        try await mac.sync()

        clock.advance(60)
        phone.meals.upsert(edited(pasta, carbs: 50))
        phone.engine.recordLocalChanges()
        clock.advance(60)
        mac.meals.upsert(edited(pasta, carbs: 70))
        mac.engine.recordLocalChanges()

        let order = phoneFirst ? [phone, mac, phone] : [mac, phone, mac]
        for device in order { try await device.sync() }

        #expect(phone.meals.load().map(\.carbsGrams) == [70])
        #expect(mac.meals.load().map(\.carbsGrams) == [70])
    }

    @Test func deletionBeatsAnOlderEditAndAStaleCopyDoesNotComeBack() async throws {
        let phone = device()
        let mac = device()
        let pasta = meal("pasta")
        phone.meals.upsert(pasta)
        try await phone.sync()
        try await mac.sync()

        clock.advance(60)
        mac.meals.upsert(edited(pasta, carbs: 70))
        mac.engine.recordLocalChanges()
        clock.advance(60)
        phone.meals.delete(id: pasta.id)
        phone.engine.recordLocalChanges()

        try await phone.sync()
        try await mac.sync()
        try await phone.sync()
        #expect(mac.meals.load().isEmpty)
        #expect(phone.meals.load().isEmpty)

        // A window still holding the Meal saves it again after the delete arrived.
        mac.meals.upsert(edited(pasta, carbs: 70))
        try await mac.sync()
        #expect(mac.meals.load().isEmpty)
        #expect(server.record(kind: "meal", id: pasta.id.uuidString)?.deleted == true)
    }

    @Test func anOlderRemoteVersionArrivingMidRequestDoesNotOverwriteANewerLocalEdit() async throws {
        let phone = device()
        let mac = device()
        let pasta = meal("pasta")
        phone.meals.upsert(pasta)
        try await phone.sync()
        try await mac.sync()

        clock.advance(60)
        mac.meals.upsert(edited(pasta, carbs: 70))
        try await mac.sync()
        clock.advance(60)
        server.duringNextSync = { [clock] in
            await MainActor.run {
                clock.advance(1)
                phone.meals.upsert(edited(pasta, carbs: 50))
                phone.engine.recordLocalChanges()
            }
        }
        try await phone.sync()
        try await mac.sync()

        #expect(phone.meals.load().map(\.carbsGrams) == [50])
        #expect(mac.meals.load().map(\.carbsGrams) == [50])
    }

    @Test func offlineEditsWaitInTheOutboxAndGoOutLater() async throws {
        let phone = device()
        let mac = device()
        server.isOffline = true
        phone.meals.upsert(meal("soup"))
        await #expect(throws: URLError.self) { try await phone.sync() }
        #expect(phone.engine.status.pendingCount == 1)
        #expect(phone.engine.status.lastError != nil)

        server.isOffline = false
        try await phone.sync()
        try await mac.sync()
        #expect(phone.engine.status.pendingCount == 0)
        #expect(phone.engine.status.lastError == nil)
        #expect(mac.meals.load().map(\.summary) == ["soup"])
    }

    @Test func aLostResponseNeitherLosesNorDuplicatesChanges() async throws {
        let phone = device()
        let mac = device()
        phone.meals.upsert(meal("soup"))
        server.lostResponses = 1
        await #expect(throws: URLError.self) { try await phone.sync() }
        #expect(server.recordCount == 1)

        phone.relaunch()
        try await phone.sync()
        try await mac.sync()
        #expect(server.recordCount == 1)
        #expect(phone.engine.status.pendingCount == 0)
        #expect(phone.meals.load().count == 1)
        #expect(mac.meals.load().count == 1)
    }

    @Test func pullsEveryPageWhenTheServerHasMoreThanOneResponseHolds() async throws {
        let phone = device()
        let mac = device()
        for index in 0..<1200 { phone.meals.save(phone.meals.load() + [meal("meal \(index)", minutesAgo: Double(index))]) }
        try await phone.sync()
        try await mac.sync()

        #expect(mac.meals.load().count == 1200)
        #expect(mac.stateStore.load()?.cursor == 1200)
    }

    @Test func firstSyncKeepsAMealsOwnTimeSoADeletionMadeElsewhereWins() async throws {
        let phone = device()
        let old = meal("pasta", minutesAgo: 600)
        phone.meals.upsert(old)
        try await phone.sync()
        clock.advance(60)
        phone.meals.delete(id: old.id)
        try await phone.sync()

        // A device restored from an old backup still holds the Meal.
        let restored = device()
        restored.meals.upsert(old)
        try await restored.sync()
        #expect(restored.meals.load().isEmpty)
        #expect(server.record(kind: "meal", id: old.id.uuidString)?.deleted == true)
    }

    // MARK: Settings on first contact

    private var realTherapy: TherapySettings { TherapySettings(insulinSensitivity: 2.5, carbRatio: 10) }

    @Test func aFreshInstallTakesTheServersSettingsAndUploadsNoDefaults() async throws {
        let mac = device()
        var settings = Settings.default
        settings.therapy = realTherapy
        mac.settings.save(settings)
        try await mac.sync()
        let stored = try #require(server.record(kind: "therapy", id: "default"))

        let phone = device()
        try await phone.sync()
        #expect(phone.settings.load().therapy == realTherapy)
        #expect(server.record(kind: "therapy", id: "default") == stored)
        #expect(server.record(kind: "thresholds", id: "default") == nil)
        #expect(phone.applied.contains { $0.settings })
    }

    @Test func onFirstContactTheServersSettingsWinOverLocalOnes() async throws {
        let mac = device()
        var macSettings = Settings.default
        macSettings.therapy = realTherapy
        mac.settings.save(macSettings)
        try await mac.sync()

        let phone = device()
        var phoneSettings = Settings.default
        phoneSettings.therapy = TherapySettings(insulinSensitivity: 3, carbRatio: 12)
        phone.settings.save(phoneSettings)
        try await phone.sync()
        #expect(phone.settings.load().therapy == realTherapy)
    }

    @Test func defaultsWaitForRealSettingsFromAnotherDevice() async throws {
        let phone = device()
        try await phone.sync()
        #expect(server.recordCount == 0)

        let mac = device()
        var settings = Settings.default
        settings.therapy = realTherapy
        mac.settings.save(settings)
        clock.advance(60)
        try await mac.sync()
        try await phone.sync()
        #expect(phone.settings.load().therapy == realTherapy)
    }

    @Test func aChangeAfterFirstContactIsUploaded() async throws {
        let mac = device()
        var settings = Settings.default
        settings.therapy = realTherapy
        mac.settings.save(settings)
        try await mac.sync()
        let phone = device()
        try await phone.sync()

        clock.advance(60)
        var changed = phone.settings.load()
        changed.thresholds = Thresholds(urgentLow: 3.1, low: 4.0, high: 9.0, urgentHigh: 13)
        changed.dosing.targetGlucose = 6.5
        phone.settings.save(changed)
        try await phone.sync()
        try await mac.sync()

        #expect(mac.settings.load().thresholds == changed.thresholds)
        #expect(mac.settings.load().dosing.targetGlucose == 6.5)
        #expect(mac.settings.load().therapy == realTherapy)
    }

    @Test func perDeviceSettingsStayOnTheDevice() async throws {
        let mac = device()
        var settings = Settings.default
        settings.pollCadence = 120
        settings.selectedPatientId = "patient"
        settings.disclaimerAcknowledged = true
        settings.therapy = realTherapy
        mac.settings.save(settings)
        try await mac.sync()
        let phone = device()
        try await phone.sync()

        #expect(phone.settings.load().therapy == realTherapy)
        #expect(phone.settings.load().pollCadence == Settings.default.pollCadence)
        #expect(phone.settings.load().selectedPatientId == nil)
        #expect(!phone.settings.load().disclaimerAcknowledged)
    }

    @Test func unchangedSettingsAreNotSentAgainOnLaterLaunches() async throws {
        let mac = device()
        var settings = Settings.default
        settings.alerts.isEnabled = true
        settings.alerts.enabledLevels = [.urgentLow, .low, .high, .urgentHigh]
        mac.settings.save(settings)
        try await mac.sync()
        let count = server.recordCount

        clock.advance(60)
        mac.relaunch()
        mac.engine.recordLocalChanges()
        #expect(mac.engine.status.pendingCount == 0)
        try await mac.sync()
        #expect(server.recordCount == count)
    }

    // MARK: Readings and Glooko Doses

    private func readings(count: Int, endingAt end: Date, every interval: TimeInterval = 300) -> [Reading] {
        (0..<count).map { Reading(value: 5 + Double($0 % 40) / 10, timestamp: end.addingTimeInterval(-Double(count - 1 - $0) * interval), trend: .stable) }
    }

    @Test func uploadsReadingsInBatchesAndResumesWhereItStopped() async throws {
        let phone = SimulatedDevice(server: server, clock: clock, readingBatchSize: 5000)
        phone.history.append(readings: readings(count: 12_000, endingAt: clock.now))
        server.failReadingsUpload = 2
        await #expect(throws: URLError.self) { try await phone.sync() }
        #expect(server.postedReadings < 12_000)

        phone.relaunch()
        try await phone.sync()
        #expect(server.storedReadings.count == 12_000)
        #expect(server.postedReadings == 12_000)

        try await phone.sync()
        #expect(server.postedReadings == 12_000)

        // A late Backfill into an old month sends that month again, and only that month.
        let oldest = phone.history.earliestReadingDate()!
        phone.history.append(readings: [Reading(value: 7, timestamp: oldest.addingTimeInterval(150), trend: .notDetermined)])
        let monthCount = phone.history.readings(in: MonthKey(oldest).interval).count
        try await phone.sync()
        #expect(server.storedReadings.count == 12_001)
        #expect(server.postedReadings == 12_000 + monthCount)
    }

    @Test func downloadsReadingsAndGlookoDosesFromOtherDevices() async throws {
        let phone = device()
        let mac = device()
        let recent = readings(count: 300, endingAt: clock.now)
        let pen = InsulinDose(kind: .bolus, units: 5, timestamp: clock.now.addingTimeInterval(-3600), insulinName: "Fiasp", deviceName: "NovoPen 6")
        phone.history.append(readings: recent)
        phone.history.append(doses: [pen])
        mac.history.append(readings: [recent[100]])
        try await phone.sync()
        try await mac.sync()

        let window = clock.now.addingTimeInterval(-86400)...clock.now
        #expect(mac.history.readings(in: window) == phone.history.readings(in: window))
        #expect(mac.history.allDoses() == [pen])
        #expect(mac.applied.contains { $0.history })
        #expect(mac.stateStore.load()?.readingsUploaded.values.reduce(0, +) == 300)

        let posted = server.postedReadings
        try await mac.sync()
        #expect(server.postedReadings == posted)
    }

    @Test func formatsAndParsesWireTimestampsToTheMillisecond() {
        let stamp: SyncStamp = 1_763_294_400_123
        #expect(SyncTimestamp.format(stamp) == "2025-11-16T12:00:00.123Z")
        #expect(SyncTimestamp.parse("2025-11-16T12:00:00.123Z") == stamp)
        #expect(SyncTimestamp.parse("2025-11-16T12:00:00Z") == 1_763_294_400_000)
    }
}

@MainActor
@Suite struct SyncCoordinatorTests {
    @Test func makesNoNetworkCallsWhenSyncIsOff() async throws {
        let server = FakeSyncServer()
        let meals = InMemoryMealStore()
        let engine = SyncEngine(
            configuration: { nil },
            stateStore: InMemorySyncStateStore(),
            meals: meals,
            history: InMemoryHistoryStore(),
            settings: InMemorySettingsStore(),
            transport: server
        )
        let coordinator = SyncCoordinator(engine: engine, isConfigured: { false }, debounce: .milliseconds(1))
        meals.upsert(Meal(timestamp: Date(), carbsGrams: 20, summary: "apple"))
        coordinator.localChangeHappened()
        coordinator.appBecameActive()
        coordinator.pollSucceeded()
        coordinator.syncNow()
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.requests.isEmpty)
        #expect(!coordinator.isSyncing)
    }

    @Test func backsOffAfterFailuresUpToHalfAnHour() {
        #expect(syncRetryDelay(afterFailures: 1) == 30)
        #expect(syncRetryDelay(afterFailures: 3) == 120)
        #expect(syncRetryDelay(afterFailures: 20) == 1800)
    }
}
