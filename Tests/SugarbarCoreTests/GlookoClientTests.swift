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
private let dosesJSON = """
{
  "series": {
    "cgmDeviceDataBrand": "FreeStyle",
    "gkInsulinBolus": [
      { "name": "Novorapid®", "units": "units", "timestamp": "2026-10-12T17:14:02.000Z", "x": 1791825242,
        "y": 4.0, "delivered": true, "value": 4.0, "group": "gkInsulin",
        "deviceName": "Novo Nordisk NovoPen® 6/Echo Plus" }
    ],
    "gkInsulinBasal": [
      { "name": "Tresiba", "units": "units", "timestamp": "2026-10-12T08:35:00.000Z", "x": 1791794100,
        "y": 9.0, "delivered": false, "value": 9.0, "group": "gkInsulin", "deviceName": null }
    ]
  },
  "devices": ["NOVO_NOVOPEN"]
}
"""

private let oslo = TimeZone(identifier: "Europe/Oslo")!

@Suite struct GlookoDecodingTests {
    @Test func decodesPenBolusAndManualBasalAsWallClockTime() throws {
        let doses = try decodeGlookoDoses(Data(dosesJSON.utf8), timeZone: oslo)

        #expect(doses.count == 2)
        #expect(doses[0].kind == .basal)
        #expect(doses[0].units == 9)
        #expect(doses[0].insulinName == "Tresiba")
        #expect(doses[0].isManualEntry)
        // "08:35:00.000Z" is 08:35 Oslo time (UTC+2 in October), i.e. 06:35Z.
        #expect(doses[0].timestamp == Date(timeIntervalSince1970: 1_791_794_100 - 7200))

        #expect(doses[1].kind == .bolus)
        #expect(doses[1].units == 4)
        #expect(doses[1].deviceName == "Novo Nordisk NovoPen® 6/Echo Plus")
        #expect(!doses[1].isManualEntry)
        #expect(doses[1].timestamp == Date(timeIntervalSince1970: 1_791_825_242 - 7200))
    }

    @Test func toleratesMissingSeries() throws {
        #expect(try decodeGlookoDoses(Data(#"{ "series": {} }"#.utf8)).isEmpty)
    }

    @Test func parsesDashboardBootstrap() {
        let dashboard = parseDashboard(dashboardHTML)
        #expect(dashboard?.patientId == "eu-west-1-patient-42")
        #expect(dashboard?.apiBase == URL(string: "https://eu.api.glooko.com"))
        #expect(parseDashboard(loginPageHTML) == nil)
    }

    @Test func formEncodesReservedCharacters() {
        #expect(formURLEncoded([("user[email]", "a+b@c.no"), ("pw", "x y&z")]) == "user%5Bemail%5D=a%2Bb%40c.no&pw=x+y%26z")
    }
}

@Suite struct GlookoClientFlowTests {
    private func stubHappyPath(_ transport: FakeTransport) async {
        await transport.stub(host: "my.glooko.com", path: "/users/sign_in", json: loginPageHTML)
        await transport.stub(
            host: "my.glooko.com", path: "/users/sign_in", json: dashboardHTML,
            url: URL(string: "https://eu.my.glooko.com/dashboard")
        )
        await transport.stub(host: "eu.api.glooko.com", path: "/api/v3/graph/data", json: dosesJSON)
    }

    @Test func signsInWithFormAndQueriesInsulinSeriesForPatient() async throws {
        let transport = FakeTransport()
        await stubHappyPath(transport)

        let client = GlookoClient(transport: transport, timeZone: oslo)
        let doses = try await client.fetchDoses(
            email: "a@b.no", password: "p w",
            from: Date(timeIntervalSince1970: 1_791_700_000), to: Date(timeIntervalSince1970: 1_791_800_000)
        )
        #expect(doses.count == 2)

        let login = try #require(await transport.lastRequest(host: "my.glooko.com", path: "/users/sign_in"))
        #expect(login.httpMethod == "POST")
        #expect(login.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let loginBody = try #require(login.httpBody)
        let body = String(decoding: loginBody, as: UTF8.self)
        #expect(body == "authenticity_token=tok-1&user%5Bemail%5D=a%40b.no&user%5Bpassword%5D=p+w&commit=Log+In")

        let graph = try #require(await transport.lastRequest(host: "eu.api.glooko.com", path: "/api/v3/graph/data"))
        let graphURL = try #require(graph.url)
        let query = try #require(URLComponents(url: graphURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "patient", value: "eu-west-1-patient-42")))
        // Query bounds are sent as Oslo wall-clock time with a literal Z, matching Glooko's convention.
        #expect(query.contains(URLQueryItem(name: "startDate", value: "2026-10-11T08:26:40.000Z")))
        #expect(query.filter { $0.name == "series[]" }.map(\.value) == ["gkInsulinBolus", "gkInsulinBasal"])
        #expect(graph.value(forHTTPHeaderField: "Origin") == "https://eu.my.glooko.com")
        #expect(graph.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
    }

    @Test func rejectedSignInIsAuthenticationFailure() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "my.glooko.com", path: "/users/sign_in", json: loginPageHTML)

        let client = GlookoClient(transport: transport)
        await #expect(throws: GlookoError.authenticationFailed) {
            try await client.fetchDoses(email: "a@b.no", password: "bad", from: .distantPast, to: .distantFuture)
        }
    }

    @Test func reauthenticatesOnceWhenSessionBouncesToSignInPage() async throws {
        let transport = FakeTransport()
        await transport.stub(host: "my.glooko.com", path: "/users/sign_in", json: loginPageHTML)
        await transport.stub(host: "my.glooko.com", path: "/users/sign_in", json: dashboardHTML, url: URL(string: "https://eu.my.glooko.com/dashboard"))
        await transport.stub(host: "my.glooko.com", path: "/users/sign_in", json: loginPageHTML)
        await transport.stub(host: "my.glooko.com", path: "/users/sign_in", json: dashboardHTML, url: URL(string: "https://eu.my.glooko.com/dashboard"))
        await transport.stub(host: "eu.api.glooko.com", path: "/api/v3/graph/data", json: dosesJSON)
        await transport.stub(host: "eu.api.glooko.com", path: "/api/v3/graph/data", json: loginPageHTML)
        await transport.stub(host: "eu.api.glooko.com", path: "/api/v3/graph/data", json: dosesJSON)

        let client = GlookoClient(transport: transport)
        _ = try await client.fetchDoses(email: "a@b.no", password: "pw", from: .distantPast, to: .distantFuture)
        #expect(await transport.requestCount(host: "my.glooko.com", path: "/users/sign_in") == 2)

        let doses = try await client.fetchDoses(email: "a@b.no", password: "pw", from: .distantPast, to: .distantFuture)
        #expect(doses.count == 2)
        #expect(await transport.requestCount(host: "my.glooko.com", path: "/users/sign_in") == 4)
        #expect(await transport.requestCount(host: "eu.api.glooko.com", path: "/api/v3/graph/data") == 3)
    }
}

@Suite struct InsulinDoseTests {
    @Test func windowsAndTotalsDoses() {
        let now = Date(timeIntervalSince1970: 1_791_800_000)
        let doses = [
            InsulinDose(kind: .basal, units: 10, timestamp: now.addingTimeInterval(-5 * 3600), insulinName: nil, deviceName: nil),
            InsulinDose(kind: .bolus, units: 4, timestamp: now.addingTimeInterval(-3 * 3600), insulinName: nil, deviceName: "pen"),
            InsulinDose(kind: .bolus, units: 1.5, timestamp: now.addingTimeInterval(-600), insulinName: nil, deviceName: "pen"),
        ]
        let recent = insulinDoses(doses, within: .fourHours, of: now)
        #expect(recent.map(\.units) == [4, 1.5])
        #expect(insulinTotals(recent) == InsulinTotals(bolus: 5.5, basal: 0))
        #expect(insulinDoses(near: now.addingTimeInterval(-500), in: doses, tolerance: 300).map(\.units) == [1.5])
        #expect(insulinDoses(near: now.addingTimeInterval(-1000), in: doses, tolerance: 300).isEmpty)
        #expect(formatUnits(1.5) == "1.5")
        #expect(formatUnits(10) == "10")
    }
}
