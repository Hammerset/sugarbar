import Foundation
import Testing

@testable import SugarbarCore

@Suite struct AccountIdTests {
    @Test func derivesLowercaseHexSha256OfUserId() {
        #expect(accountIdHeader(forUserId: "abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct GraphDecodingTests {
    @Test func decodesLatestReadingFromGlucoseMeasurement() throws {
        let json = Data("""
        {
          "status": 0,
          "data": {
            "connection": {
              "glucoseMeasurement": {
                "FactoryTimestamp": "6/26/2026 5:12:00 PM",
                "Timestamp": "6/26/2026 7:12:00 PM",
                "ValueInMgPerDl": 100,
                "Value": 5.5,
                "TrendArrow": 4
              }
            },
            "graphData": []
          }
        }
        """.utf8)

        let reading = try decodeLatestReading(json)

        #expect(abs(reading.value - 5.55) < 0.01)
        #expect(reading.trend == .rising)

        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 26
        components.hour = 17
        components.minute = 12
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: components)!
        #expect(abs(reading.timestamp.timeIntervalSince(expected)) < 1)
    }

    @Test func defaultsToNotDeterminedWhenTrendMissing() throws {
        let json = Data("""
        {
          "status": 0,
          "data": {
            "connection": {
              "glucoseMeasurement": {
                "FactoryTimestamp": "6/26/2026 5:12:00 PM",
                "ValueInMgPerDl": 90
              }
            },
            "graphData": []
          }
        }
        """.utf8)

        let reading = try decodeLatestReading(json)
        #expect(reading.trend == .notDetermined)
    }

    @Test func decodesHistoryFromGraphData() throws {
        let json = Data("""
        {
          "status": 0,
          "data": {
            "connection": {
              "glucoseMeasurement": {
                "FactoryTimestamp": "6/26/2026 5:12:00 PM",
                "ValueInMgPerDl": 100,
                "TrendArrow": 4
              }
            },
            "graphData": [
              { "FactoryTimestamp": "6/26/2026 3:12:00 PM", "ValueInMgPerDl": 90 },
              { "FactoryTimestamp": "6/26/2026 4:12:00 PM", "ValueInMgPerDl": 180 }
            ]
          }
        }
        """.utf8)

        let snapshot = try decodeGraph(json)

        #expect(abs(snapshot.latest.value - 5.55) < 0.01)
        #expect(snapshot.history.count == 2)
        #expect(snapshot.history[0].value.isApprox(5.0, tolerance: 0.01))
        #expect(snapshot.history[1].value.isApprox(9.99, tolerance: 0.01))
        // Historical points carry no trend arrow.
        #expect(snapshot.history.allSatisfy { $0.trend == .notDetermined })
        #expect(snapshot.history[0].timestamp < snapshot.history[1].timestamp)
    }

    @Test func skipsHistoryEntriesWithUnparseableTimestamp() throws {
        let json = Data("""
        {
          "status": 0,
          "data": {
            "connection": {
              "glucoseMeasurement": {
                "FactoryTimestamp": "6/26/2026 5:12:00 PM",
                "ValueInMgPerDl": 100
              }
            },
            "graphData": [
              { "FactoryTimestamp": "not-a-date", "ValueInMgPerDl": 90 },
              { "FactoryTimestamp": "6/26/2026 4:12:00 PM", "ValueInMgPerDl": 180 }
            ]
          }
        }
        """.utf8)

        let snapshot = try decodeGraph(json)
        #expect(snapshot.history.count == 1)
    }
}

private extension Double {
    func isApprox(_ other: Double, tolerance: Double = 0.01) -> Bool {
        abs(self - other) < tolerance
    }
}

@Suite struct ConnectionsDecodingTests {
    @Test func decodesConnectionList() throws {
        let json = Data("""
        {
          "status": 0,
          "data": [
            { "patientId": "p-1", "firstName": "Ada", "lastName": "Lovelace" },
            { "patientId": "p-2", "firstName": "Alan", "lastName": "Turing" }
          ]
        }
        """.utf8)
        let connections = try decodeConnections(json)
        #expect(connections == [
            Connection(patientId: "p-1", firstName: "Ada", lastName: "Lovelace"),
            Connection(patientId: "p-2", firstName: "Alan", lastName: "Turing"),
        ])
    }

    @Test func decodesEmptyConnectionList() throws {
        let json = Data(#"{ "status": 0, "data": [] }"#.utf8)
        #expect(try decodeConnections(json).isEmpty)
    }
}

@Suite struct LoginDecodingTests {
    @Test func decodesRegionRedirect() throws {
        let json = Data("""
        { "status": 0, "data": { "redirect": true, "region": "eu2" } }
        """.utf8)
        #expect(try decodeLogin(json) == .redirect(region: "eu2"))
    }

    @Test func decodesSuccessfulAuth() throws {
        let json = Data("""
        {
          "status": 0,
          "data": {
            "authTicket": { "token": "jwt-123", "expires": 1750000000, "duration": 15552000 },
            "user": { "id": "user-xyz" }
          }
        }
        """.utf8)
        #expect(try decodeLogin(json) == .success(token: "jwt-123", userId: "user-xyz"))
    }

    @Test func throwsTermsNotAcceptedOnStatus4() {
        let json = Data(#"{ "status": 4 }"#.utf8)
        #expect(throws: LibreLinkUpError.termsNotAccepted) {
            try decodeLogin(json)
        }
    }

    @Test func throwsAuthenticationFailedOnOtherNonZeroStatus() {
        let json = Data(#"{ "status": 2 }"#.utf8)
        #expect(throws: LibreLinkUpError.authenticationFailed) {
            try decodeLogin(json)
        }
    }
}
