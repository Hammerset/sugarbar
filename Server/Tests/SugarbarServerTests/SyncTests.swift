import Foundation
import HummingbirdTesting
import Synchronization
import Testing
@testable import SugarbarServer

@Suite struct SyncTests {
    @Test func healthNeedsNoToken() async throws {
        try await withServer { client in
            let response = try await client.send(.get, "/v1/health", token: nil)
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == #"{"status":"ok"}"#)
        }
    }

    @Test func rejectsMissingAndUnknownTokens() async throws {
        let token = try await createAccount()
        try await withServer { client in
            for candidate in [nil, "nope", "Basic \(token)"] as [String?] {
                let response = try await client.send(.post, "/v1/sync", token: candidate, raw: .init(string: "{}"))
                #expect(response.status == .unauthorized)
                #expect(try JSONDecoder().decode(ErrorReply.self, from: response.body).error == "unauthorized")
            }
            let response = try await client.send(.get, "/v1/readings", token: token)
            #expect(response.status == .ok)
        }
    }

    @Test func latestEditWinsAndEqualTimestampsKeepTheStoredRecord() async throws {
        let token = try await createAccount()
        try await withServer { client in
            _ = try await client.sync(token: token, changes: [Change(id: "m1", updatedAt: iso(10), payload: .object(["carbs": .int(40)]))])
            _ = try await client.sync(token: token, changes: [
                Change(id: "m1", updatedAt: iso(5), payload: .object(["carbs": .int(1)])),
                Change(id: "m1", updatedAt: iso(10), payload: .object(["carbs": .int(2)])),
            ])
            var stored = try await client.syncAll(token: token)
            #expect(stored.count == 1)
            #expect(stored[0].payload == .object(["carbs": .int(40)]))
            #expect(stored[0].updatedAt == iso(10))

            _ = try await client.sync(token: token, changes: [Change(id: "m1", updatedAt: iso(10.001), payload: .object(["carbs": .int(55)]))])
            stored = try await client.syncAll(token: token)
            #expect(stored.map(\.payload) == [.object(["carbs": .int(55)])])
        }
    }

    @Test func deletesTravelAndBeatOlderEdits() async throws {
        let token = try await createAccount()
        try await withServer { client in
            let first = try await client.sync(token: token, changes: [Change(id: "m1", updatedAt: iso(0), payload: .object(["carbs": .int(40)]))])
            let afterDelete = try await client.sync(token: token, cursor: first.cursor, changes: [
                Change(id: "m1", updatedAt: iso(60), deleted: true, payload: nil),
            ])
            #expect(afterDelete.changes.count == 1)
            #expect(afterDelete.changes[0].deleted)
            #expect(afterDelete.changes[0].payload == .object([:]))
            #expect(afterDelete.changes[0].seq! > first.cursor)

            _ = try await client.sync(token: token, changes: [Change(id: "m1", updatedAt: iso(30), payload: .object(["carbs": .int(1)]))])
            let stored = try await client.syncAll(token: token)
            #expect(stored.count == 1 && stored[0].deleted)
        }
    }

    @Test func pagesBeyondFiveHundredRecordsOldestFirst() async throws {
        let token = try await createAccount()
        try await withServer { client in
            for batch in 0..<4 {
                let changes = (0..<300).map { Change(kind: "meal", id: "m\(batch * 300 + $0)", updatedAt: iso(Double($0))) }
                _ = try await client.sync(token: token, changes: changes)
            }
            var cursor: Int64 = 0
            var pages: [(count: Int, hasMore: Bool)] = []
            var seqs: [Int64] = []
            repeat {
                let reply = try await client.sync(token: token, cursor: cursor)
                pages.append((reply.changes.count, reply.hasMore))
                seqs += reply.changes.compactMap(\.seq)
                cursor = reply.cursor
                #expect(reply.cursor == reply.changes.last?.seq ?? cursor)
            } while pages.last!.hasMore
            #expect(pages.map(\.count) == [500, 500, 200])
            #expect(pages.map(\.hasMore) == [true, true, false])
            #expect(seqs == seqs.sorted() && Set(seqs).count == 1200)

            let empty = try await client.sync(token: token, cursor: cursor)
            #expect(empty.changes.isEmpty && empty.cursor == cursor && !empty.hasMore)
        }
    }

    @Test func accountsAreIsolated() async throws {
        let alice = try await createAccount()
        let bob = try await createAccount()
        try await withServer { client in
            _ = try await client.sync(token: alice, changes: [Change(kind: "therapy", id: "default", updatedAt: iso(0), payload: .object(["isf": .double(2.5)]))])
            _ = try await client.sync(token: bob, changes: [Change(kind: "therapy", id: "default", updatedAt: iso(-100), payload: .object(["isf": .double(3)]))])
            _ = try await client.decode(Stored.self, .post, "/v1/readings", token: alice, json: ["readings": [["t": 1000, "v": 6.4, "trend": 3]]])

            #expect(try await client.syncAll(token: alice).map(\.payload) == [.object(["isf": .double(2.5)])])
            #expect(try await client.syncAll(token: bob).map(\.payload) == [.object(["isf": .int(3)])])
            #expect(try await client.decode(ReadingsReply.self, .get, "/v1/readings", token: bob).readings.isEmpty)
        }
    }

    /// Two devices write while a third keeps pulling with its cursor: once the writers stop and
    /// the reader catches up, it must have seen every record, which fails if a cursor ever moves
    /// past a seq whose transaction had not committed yet.
    @Test func concurrentWritersNeverHideAChangeFromACursorReader() async throws {
        let token = try await createAccount()
        try await withServer { client in
            let writersDone = Flag()
            async let reader: [String: Change] = {
                var cursor: Int64 = 0
                var seen: [String: Change] = [:]
                while true {
                    let finished = writersDone.isSet
                    let reply = try await client.sync(token: token, cursor: cursor)
                    for change in reply.changes { seen[change.id] = change }
                    cursor = reply.cursor
                    if finished && !reply.hasMore { return seen }
                }
            }()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for writer in 0..<4 {
                    group.addTask {
                        for round in 0..<60 {
                            var changes = (0..<5).map { Change(id: "w\(writer)-\(round)-\($0)", updatedAt: iso(Double(round))) }
                            changes.append(Change(id: "shared", updatedAt: iso(Double(round * 4 + writer)), payload: .object(["by": .int(Int64(writer))])))
                            _ = try await client.sync(token: token, changes: changes)
                        }
                    }
                }
                try await group.waitForAll()
            }
            writersDone.set()
            let seen = try await reader
            let stored = Dictionary(uniqueKeysWithValues: try await client.syncAll(token: token).map { ($0.id, $0) })
            let expectedCount = 4 * 60 * 5 + 1
            #expect(stored.count == expectedCount)
            #expect(Set(seen.keys) == Set(stored.keys))
            #expect(seen["shared"] == stored["shared"])
            #expect(stored["shared"]?.payload == .object(["by": .int(3)]))
        }
    }

    @Test func malformedBodiesAreRejectedWithAnError() async throws {
        let token = try await createAccount()
        try await withServer { client in
            let bodies = [
                "not json",
                #"{"cursor":0,"changes":[{"kind":"meal","id":"a","deleted":false}]}"#,
                #"{"cursor":0,"changes":[{"kind":"meal","id":"a","updatedAt":"yesterday","deleted":false}]}"#,
                #"{"cursor":"zero"}"#,
            ]
            for body in bodies {
                let response = try await client.send(.post, "/v1/sync", token: token, raw: .init(string: body))
                #expect(response.status == .badRequest, "\(body)")
                #expect(!(try JSONDecoder().decode(ErrorReply.self, from: response.body).error.isEmpty))
            }
            let readings = try await client.send(.post, "/v1/readings", token: token, raw: .init(string: #"{"readings":[{"t":1}]}"#))
            #expect(readings.status == .badRequest)
            let query = try await client.send(.get, "/v1/readings?limit=lots", token: token)
            #expect(query.status == .badRequest)
        }
    }

    @Test func bodiesOverTwoMegabytesAreRejected() async throws {
        let token = try await createAccount()
        try await withServer { client in
            let padding = String(repeating: "x", count: 2 * 1024 * 1024)
            let response = try await client.send(.post, "/v1/sync", token: token, raw: .init(string: #"{"cursor":0,"pad":"\#(padding)"}"#))
            #expect(response.status == .contentTooLarge)
            #expect(!(try JSONDecoder().decode(ErrorReply.self, from: response.body).error.isEmpty))
        }
    }
}

final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
