import Foundation
import Testing

@testable import SugarbarCore

private let redirectJSON = #"{ "status": 0, "data": { "redirect": true, "region": "eu2" } }"#
private let loginSuccessJSON = """
{
  "status": 0,
  "data": {
    "authTicket": { "token": "jwt-123", "expires": 1750000000 },
    "user": { "id": "user-xyz" }
  }
}
"""
private let connectionsJSON = #"{ "status": 0, "data": [ { "patientId": "p-1", "firstName": "Ada", "lastName": "L" } ] }"#
private let graphJSON = """
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
      { "FactoryTimestamp": "6/26/2026 4:12:00 PM", "ValueInMgPerDl": 110 }
    ]
  }
}
"""

@Suite struct LibreLinkUpClientFlowTests {
    @Test func fetchesLatestReadingFollowingRegionRedirect() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/auth/login", json: redirectJSON)
        await transport.stub(host: "api-eu2.libreview.io", path: "/llu/auth/login", json: loginSuccessJSON)
        await transport.stub(host: "api-eu2.libreview.io", path: "/llu/connections", json: connectionsJSON)
        await transport.stub(host: "api-eu2.libreview.io", path: "/llu/connections/p-1/graph", json: graphJSON)

        let client = LibreLinkUpClient(transport: transport, appVersion: "4.12.0")
        let reading = try await client.fetchLatestReading(email: "a@b.no", password: "pw")

        #expect(abs(reading.value - 5.55) < 0.01)
        #expect(reading.trend == .rising)

        let graphRequest = await transport.lastRequest(host: "api-eu2.libreview.io", path: "/llu/connections/p-1/graph")
        let request = try #require(graphRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-123")
        #expect(request.value(forHTTPHeaderField: "account-id") == accountIdHeader(forUserId: "user-xyz"))
        #expect(request.value(forHTTPHeaderField: "product") == "llu.android")
        #expect(request.value(forHTTPHeaderField: "version") == "4.12.0")
    }

    @Test func fetchesGraphSnapshotWithHistoryFollowingRedirect() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/auth/login", json: redirectJSON)
        await transport.stub(host: "api-eu2.libreview.io", path: "/llu/auth/login", json: loginSuccessJSON)
        await transport.stub(host: "api-eu2.libreview.io", path: "/llu/connections", json: connectionsJSON)
        await transport.stub(host: "api-eu2.libreview.io", path: "/llu/connections/p-1/graph", json: graphJSON)

        let client = LibreLinkUpClient(transport: transport)
        let snapshot = try await client.fetchGraph(email: "a@b.no", password: "pw")

        #expect(abs(snapshot.latest.value - 5.55) < 0.01)
        #expect(snapshot.latest.trend == .rising)
        #expect(snapshot.history.count == 2)
        #expect(snapshot.history[0].timestamp < snapshot.history[1].timestamp)
    }

    @Test func sendsCredentialsAndBaseHeadersOnLogin() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/auth/login", json: loginSuccessJSON)
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/connections", json: connectionsJSON)
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/connections/p-1/graph", json: graphJSON)

        let client = LibreLinkUpClient(transport: transport, appVersion: "4.12.0")
        _ = try await client.fetchLatestReading(email: "a@b.no", password: "secret")

        let login = try #require(await transport.lastRequest(host: "api-eu.libreview.io", path: "/llu/auth/login"))
        #expect(login.httpMethod == "POST")
        #expect(login.value(forHTTPHeaderField: "product") == "llu.android")
        #expect(login.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(login.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded?["email"] == "a@b.no")
        #expect(decoded?["password"] == "secret")
    }

    @Test func throwsNoConnectionsWhenListEmpty() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/auth/login", json: loginSuccessJSON)
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/connections", json: #"{ "status": 0, "data": [] }"#)

        let client = LibreLinkUpClient(transport: transport)
        await #expect(throws: LibreLinkUpError.noConnections) {
            try await client.fetchLatestReading(email: "a@b.no", password: "pw")
        }
    }

    @Test func mapsRateLimitStatusToError() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/auth/login", status: 429, json: "{}")

        let client = LibreLinkUpClient(transport: transport)
        await #expect(throws: LibreLinkUpError.rateLimited) {
            try await client.fetchLatestReading(email: "a@b.no", password: "pw")
        }
    }
}

actor FakeTransport: HTTPTransport {
    private var stubs: [String: HTTPResponse] = [:]
    private(set) var requests: [URLRequest] = []

    func stub(host: String, path: String, status: Int = 200, json: String) {
        stubs[key(host: host, path: path)] = HTTPResponse(status: status, body: Data(json.utf8))
    }

    func lastRequest(host: String, path: String) -> URLRequest? {
        requests.last { $0.url?.host == host && $0.url?.path == path }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        return stubs[key(host: host, path: path)] ?? HTTPResponse(status: 404, body: Data())
    }

    private func key(host: String, path: String) -> String { "\(host)\(path)" }
}
