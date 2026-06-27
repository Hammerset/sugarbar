import Foundation
import Testing

@testable import SugarbarCore

private let ada = Connection(patientId: "p-1", firstName: "Ada", lastName: "L")
private let grace = Connection(patientId: "p-2", firstName: "Grace", lastName: "H")

@Suite struct ConnectionSelectionTests {
    @Test func returnsNilWhenEmpty() {
        #expect(selectedConnection(from: [], preferredPatientId: nil) == nil)
        #expect(selectedConnection(from: [], preferredPatientId: "p-1") == nil)
    }

    @Test func autoSelectsSoleConnection() {
        #expect(selectedConnection(from: [ada], preferredPatientId: nil) == ada)
    }

    @Test func honoursValidPreference() {
        #expect(selectedConnection(from: [ada, grace], preferredPatientId: "p-2") == grace)
    }

    @Test func fallsBackToFirstWhenPreferenceMissing() {
        #expect(selectedConnection(from: [ada, grace], preferredPatientId: "gone") == ada)
        #expect(selectedConnection(from: [ada, grace], preferredPatientId: nil) == ada)
    }
}

private let loginSuccessJSON = """
{ "status": 0, "data": { "authTicket": { "token": "jwt-123" }, "user": { "id": "user-xyz" } } }
"""
private let twoConnectionsJSON = """
{ "status": 0, "data": [
  { "patientId": "p-1", "firstName": "Ada", "lastName": "L" },
  { "patientId": "p-2", "firstName": "Grace", "lastName": "H" }
] }
"""
private let graphJSON = """
{ "status": 0, "data": {
  "connection": { "glucoseMeasurement": { "FactoryTimestamp": "6/26/2026 5:12:00 PM", "ValueInMgPerDl": 100, "TrendArrow": 3 } },
  "graphData": []
} }
"""

@Suite struct LibreLinkUpConnectionTests {
    @Test func listsConnections() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/auth/login", json: loginSuccessJSON)
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/connections", json: twoConnectionsJSON)

        let client = LibreLinkUpClient(transport: transport)
        let connections = try await client.connections(email: "a@b.no", password: "pw")

        #expect(connections.map(\.patientId) == ["p-1", "p-2"])
    }

    @Test func fetchesGraphForPreferredConnection() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/auth/login", json: loginSuccessJSON)
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/connections", json: twoConnectionsJSON)
        await transport.stub(host: "api-eu.libreview.io", path: "/llu/connections/p-2/graph", json: graphJSON)

        let client = LibreLinkUpClient(transport: transport)
        _ = try await client.fetchGraph(email: "a@b.no", password: "pw", preferredPatientId: "p-2")

        #expect(await transport.lastRequest(host: "api-eu.libreview.io", path: "/llu/connections/p-2/graph") != nil)
        #expect(await transport.lastRequest(host: "api-eu.libreview.io", path: "/llu/connections/p-1/graph") == nil)
    }
}
