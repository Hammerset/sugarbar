import Foundation

@testable import SugarbarCore

/// The v1 contract's semantics in memory: strictly-later wins per record, a global seq, pages of 500.
final class FakeSyncServer: HTTPTransport, @unchecked Sendable {
    struct Stored {
        var change: SyncChange
        var seq: Int64
    }

    private let lock = NSLock()
    private var records: [String: Stored] = [:]
    private var seq: Int64 = 0
    private var readings: [WireReading] = []
    private var doses: [String: WireDose] = [:]
    private(set) var requests: [String] = []
    private(set) var postedReadings = 0
    /// Every request throws as if offline.
    var isOffline = false
    /// The next n requests are processed, then the response is lost.
    var lostResponses = 0
    /// The n-th readings upload from now fails before reaching the server.
    var failReadingsUpload: Int?
    /// Runs once while the next sync request is in flight, after the server has answered it.
    var duringNextSync: (@Sendable () async -> Void)?

    func record(kind: String, id: String) -> SyncChange? {
        lock.withLock { records["\(kind)/\(id)"]?.change }
    }

    var recordCount: Int { lock.withLock { records.count } }
    var storedReadings: [WireReading] { lock.withLock { readings } }
    var storedDoses: [WireDose] { lock.withLock { Array(doses.values) } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (response, lose): (HTTPResponse, Bool) = try lock.withLock {
            if isOffline { throw URLError(.notConnectedToInternet) }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer secret" else {
                return (HTTPResponse(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)), false)
            }
            let url = request.url!
            let path = url.path()
            requests.append("\(request.httpMethod!) \(path)")
            if request.httpMethod == "POST", path.hasSuffix("/v1/readings") {
                if let failing = failReadingsUpload {
                    failReadingsUpload = failing - 1
                    if failing == 1 {
                        failReadingsUpload = nil
                        throw URLError(.networkConnectionLost)
                    }
                }
            }
            let body = request.httpBody ?? Data()
            if body.count > SyncClient.maximumBodyBytes { return (HTTPResponse(status: 413, body: Data()), false) }
            let response = try handle(method: request.httpMethod!, path: path, query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [], body: body)
            let lose = lostResponses > 0
            if lose { lostResponses -= 1 }
            return (response, lose)
        }
        if lose { throw URLError(.networkConnectionLost) }
        let hook: (@Sendable () async -> Void)? = lock.withLock {
            guard request.url!.path().hasSuffix("/v1/sync") else { return nil }
            defer { duringNextSync = nil }
            return duringNextSync
        }
        await hook?()
        return response
    }

    private func handle(method: String, path: String, query: [URLQueryItem], body: Data) throws -> HTTPResponse {
        func number(_ name: String) -> Int? { query.first { $0.name == name }?.value.flatMap(Int.init) }
        let encoder = JSONEncoder()
        switch (method, path) {
        case ("POST", "/v1/sync"):
            let request = try JSONDecoder().decode(SyncRequest.self, from: body)
            for change in request.changes {
                let key = "\(change.kind)/\(change.id)"
                if let stored = records[key], change.updatedAt <= stored.change.updatedAt { continue }
                seq += 1
                var kept = change
                kept.payload = change.deleted ? .object([:]) : change.payload
                kept.seq = seq
                records[key] = Stored(change: kept, seq: seq)
            }
            let newer = records.values.filter { $0.seq > request.cursor }.sorted { $0.seq < $1.seq }
            let page = Array(newer.prefix(500))
            let response = SyncResponse(cursor: page.last?.seq ?? request.cursor, hasMore: newer.count > page.count, changes: page.map(\.change))
            return HTTPResponse(status: 200, body: try encoder.encode(response))
        case ("POST", "/v1/readings"):
            let incoming = try JSONDecoder().decode(ReadingsBody.self, from: body).readings
            postedReadings += incoming.count
            var stored = 0
            for reading in incoming {
                let index = readings.partitioningIndex { $0.t >= reading.t }
                if index < readings.count, readings[index].t - reading.t <= 30 { continue }
                if index > 0, reading.t - readings[index - 1].t <= 30 { continue }
                readings.insert(reading, at: index)
                stored += 1
            }
            return HTTPResponse(status: 200, body: Data(#"{"stored":\#(stored)}"#.utf8))
        case ("GET", "/v1/readings"):
            let matching = readings.filter { $0.t >= number("from")! && $0.t <= number("to")! && $0.t > (number("after") ?? Int.min) }
            let limit = number("limit") ?? 5000
            return HTTPResponse(status: 200, body: try encoder.encode(ReadingsBody(readings: Array(matching.prefix(limit)), hasMore: matching.count > limit)))
        case ("POST", "/v1/doses"):
            let incoming = try JSONDecoder().decode(DosesBody.self, from: body).doses
            for dose in incoming { doses[dose.id] = dose }
            return HTTPResponse(status: 200, body: Data(#"{"stored":\#(incoming.count)}"#.utf8))
        case ("GET", "/v1/doses"):
            let matching = doses.values
                .filter { $0.t >= number("from")! && $0.t <= number("to")! && $0.t > (number("after") ?? Int.min) }
                .sorted { ($0.t, $0.id) < ($1.t, $1.id) }
            let limit = number("limit") ?? 5000
            return HTTPResponse(status: 200, body: try encoder.encode(DosesBody(doses: Array(matching.prefix(limit)), hasMore: matching.count > limit)))
        default:
            return HTTPResponse(status: 404, body: Data())
        }
    }
}

final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) { self.now = now }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// One simulated device: its own stores and sync state, sharing a server and a clock with others.
@MainActor
final class SimulatedDevice {
    let meals = InMemoryMealStore()
    let history = InMemoryHistoryStore()
    let settings = InMemorySettingsStore()
    let stateStore = InMemorySyncStateStore()
    let server: FakeSyncServer
    let clock: TestClock
    var isConfigured = true
    private(set) var engine: SyncEngine!
    private(set) var applied: [SyncAppliedChanges] = []

    init(server: FakeSyncServer, clock: TestClock, readingBatchSize: Int = 5000) {
        self.server = server
        self.clock = clock
        relaunch(readingBatchSize: readingBatchSize)
    }

    /// A fresh engine over the same stores, as after the app was killed.
    func relaunch(readingBatchSize: Int = 5000) {
        engine = SyncEngine(
            configuration: { [unowned self] in
                isConfigured ? SyncConfiguration(serverURL: URL(string: "https://sync.example")!, token: "secret") : nil
            },
            stateStore: stateStore,
            meals: meals,
            history: history,
            settings: settings,
            transport: server,
            now: { [clock] in clock.now },
            readingBatchSize: readingBatchSize
        )
        engine.onRemoteChanges = { [unowned self] in applied.append($0) }
    }

    func sync() async throws {
        try await engine.sync()
    }
}
