import Foundation
import HummingbirdTesting
import Testing
@testable import SugarbarServer

@Suite struct ReadingAndDoseTests {
    @Test func readingsWithinThirtySecondsOfAStoredOneAreIgnored() async throws {
        let token = try await createAccount()
        try await withServer { client in
            func upload(_ ts: [Int64]) async throws -> Int {
                try await client.decode(Stored.self, .post, "/v1/readings", token: token,
                                        json: ["readings": ts.map { ["t": Double($0), "v": 5.5, "trend": 3] }]).stored
            }
            #expect(try await upload([1000, 1010, 1031]) == 2)
            #expect(try await upload([1000, 1010, 1031]) == 0)
            #expect(try await upload([1045, 1061, 975]) == 0)
            #expect(try await upload([1105, 1080]) == 1)
            let all = try await client.decode(ReadingsReply.self, .get, "/v1/readings", token: token)
            #expect(all.readings.map(\.t) == [1000, 1031, 1080])
            #expect(!all.hasMore)
        }
    }

    @Test func readingsPageOldestFirstWithAfterAndLimit() async throws {
        let token = try await createAccount()
        try await withServer { client in
            let readings: [UntrendedReading] = (0..<10).map { UntrendedReading(t: Int64(10_000 + $0 * 300), v: 6.0 + Double($0) / 10) }
            #expect(try await client.decode(Stored.self, .post, "/v1/readings", token: token, json: ["readings": readings]).stored == 10)

            let first = try await client.decode(ReadingsReply.self, .get, "/v1/readings?from=10300&to=12100&limit=3", token: token)
            #expect(first.readings.map(\.t) == [10_300, 10_600, 10_900])
            #expect(first.readings.first?.trend == 0)
            #expect(first.hasMore)
            let second = try await client.decode(ReadingsReply.self, .get, "/v1/readings?from=10300&to=12100&limit=3&after=10900", token: token)
            #expect(second.readings.map(\.t) == [11_200, 11_500, 11_800])
            let last = try await client.decode(ReadingsReply.self, .get, "/v1/readings?from=10300&to=12100&limit=3&after=11800", token: token)
            #expect(last.readings.map(\.t) == [12_100])
            #expect(!last.hasMore)
        }
    }

    @Test func firstBackfillOfTwentySixThousandReadings() async throws {
        let token = try await createAccount()
        try await withServer { client in
            let readings: [Reading] = (0..<26_000).map { Reading(t: Int64(1_755_000_000 + $0 * 300), v: 4 + Double($0 % 80) / 10, trend: 0) }
            let body = try JSONEncoder().encode(["readings": readings])
            #expect(body.count < 2 * 1024 * 1024)

            let clock = ContinuousClock()
            var stored = 0
            let first = try await clock.measure {
                stored = try await client.decode(Stored.self, .post, "/v1/readings", token: token, json: ["readings": readings]).stored
            }
            #expect(stored == 26_000)
            let again = try await clock.measure {
                stored = try await client.decode(Stored.self, .post, "/v1/readings", token: token, json: ["readings": readings]).stored
            }
            #expect(stored == 0)
            print("26,000-Reading batch (\(body.count) bytes): first upload \(first), repeat \(again)")

            let page = try await client.decode(ReadingsReply.self, .get, "/v1/readings", token: token)
            #expect(page.readings.count == 5000 && page.hasMore)
        }
    }

    @Test func aLaterDoseCopyReplacesTheEarlierOne() async throws {
        let token = try await createAccount()
        try await withServer { client in
            func upload(_ doses: [[String: JSONValue]]) async throws -> Int {
                try await client.decode(Stored.self, .post, "/v1/doses", token: token, json: ["doses": doses]).stored
            }
            #expect(try await upload([
                ["id": .string("bolus-2000"), "t": .int(2000), "payload": .object(["units": .double(4.5)])],
                ["id": .string("basal-1000"), "t": .int(1000), "payload": .object(["units": .int(18)])],
            ]) == 2)
            #expect(try await upload([["id": .string("bolus-2000"), "t": .int(2000), "payload": .object(["units": .int(5)])]]) == 1)

            let doses = try await client.decode(DosesReply.self, .get, "/v1/doses?from=0&to=5000", token: token)
            #expect(doses.doses.map(\.id) == ["basal-1000", "bolus-2000"])
            #expect(doses.doses[1].payload == .object(["units": .int(5)]))
            #expect(try await client.decode(DosesReply.self, .get, "/v1/doses?from=1500", token: token).doses.map(\.id) == ["bolus-2000"])

            let bad = try await client.send(.post, "/v1/doses", token: token, raw: .init(string: #"{"doses":[{"id":"x","t":1,"payload":3}]}"#))
            #expect(bad.status == .badRequest)
        }
    }

    @Test func aDeletedDoseStaysAsATombstoneUntilItIsUploadedAgain() async throws {
        let token = try await createAccount()
        try await withServer { client in
            func upload(_ dose: [String: JSONValue]) async throws {
                _ = try await client.decode(Stored.self, .post, "/v1/doses", token: token, json: ["doses": [dose]])
            }
            func stored() async throws -> DosesReply.Item {
                try #require(try await client.decode(DosesReply.self, .get, "/v1/doses?from=0&to=5000", token: token).doses.first)
            }
            let live: [String: JSONValue] = ["id": .string("bolus-2000"), "t": .int(2000), "payload": .object(["units": .int(4)])]
            try await upload(live)
            try await upload(["id": .string("bolus-2000"), "t": .int(2000), "payload": .object(["units": .int(4)]), "deleted": .bool(true)])

            let tombstone = try await stored()
            #expect(tombstone.deleted == true)
            #expect(tombstone.payload == .object([:]))

            try await upload(live)
            let revived = try await stored()
            #expect(revived.deleted == nil)
            #expect(revived.payload == .object(["units": .int(4)]))
        }
    }
}

struct UntrendedReading: Encodable { let t: Int64; let v: Double }
