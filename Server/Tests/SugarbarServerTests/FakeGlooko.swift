import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
@testable import SugarbarServer

/// Glooko's sign-in form, the mobile sync API (`/api/v2/foods`, `/api/v2/insulins`) and the
/// insulin graph, as far as the bridge uses them.
actor FakeGlooko {
    static let email = "owner@example.com"
    static let password = "correct horse"

    var foods: [String: [String: JSONValue]] = [:]
    var insulins: [String: [String: JSONValue]] = [:]
    var penDoses: [(kind: String, timestamp: String, units: Double)] = []
    private(set) var signIns = 0
    private(set) var puts = 0
    private var sessions: Set<String> = []
    private var lastUpdate = Date(timeIntervalSince1970: 0)

    /// The next API call answers 421, as Glooko does when the cookie session times out.
    var expireNextCall = false
    /// The next PUT is stored, but the caller sees a 500, as if it crashed before hearing back.
    var failAfterNextWrite = false
    /// Every PUT answers this instead of 204.
    var writeOverride: (status: Int, body: String)?

    private(set) var signInAttempts = 0

    func configure(_ change: @Sendable (isolated FakeGlooko) -> Void) { change(self) }

    func addAppFood(guid: String, timestamp: String, name: String, carbs: Double, deleted: Bool = false) {
        foods[guid] = [
            "guid": .string(guid), "timestamp": .string(timestamp), "name": .string(name), "carbs": .double(carbs),
            "softDeleted": .bool(deleted), "updatedAt": .string(nextUpdate()), "updatedBy": .string("GLOOKO-APP"),
        ]
    }

    var liveFoods: [[String: JSONValue]] { foods.values.filter { $0["softDeleted"] != .bool(true) } }
    var liveInsulins: [[String: JSONValue]] { insulins.values.filter { $0["softDeleted"] != .bool(true) } }

    private func nextUpdate() -> String {
        lastUpdate = max(Date(), lastUpdate.addingTimeInterval(0.001))
        return Timestamps.format(lastUpdate)
    }

    fileprivate func signIn(email: String?, password: String?) -> String? {
        signInAttempts += 1
        guard email == Self.email, password == Self.password else { return nil }
        signIns += 1
        let session = UUID().uuidString
        sessions.insert(session)
        return session
    }

    fileprivate func authorized(_ cookie: String?) -> Bool {
        if expireNextCall {
            expireNextCall = false
            sessions.removeAll()
            return false
        }
        guard let cookie, let session = cookie.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("_logbook-web_session=") })?.dropFirst("_logbook-web_session=".count)
        else { return false }
        return sessions.contains(String(session))
    }

    fileprivate func write(collection: String, items: [JSONValue]) -> (status: Int, body: String) {
        puts += 1
        if let writeOverride { return writeOverride }
        var accepted: [[String: JSONValue]] = []
        for item in items {
            guard case .object(var fields) = item, fields["guid"]?.stringValue != nil else { return (422, #"{"errors":{"guid":["missing"]}}"#) }
            guard fields["syncTimestamp"] != nil else {
                return (422, #"{"\#(collection)":[{"errors":{"syncTimestamp":["can't be blank"]}}]}"#)
            }
            fields["updatedAt"] = .string(nextUpdate())
            fields["updatedBy"] = .string("server")
            fields["syncTimestamp"] = nil
            accepted.append(fields)
        }
        for fields in accepted {
            if collection == "foods" { foods[fields["guid"]!.stringValue!] = fields } else { insulins[fields["guid"]!.stringValue!] = fields }
        }
        if failAfterNextWrite {
            failAfterNextWrite = false
            return (500, "")
        }
        return (204, "")
    }

    fileprivate func feed(after updatedAt: String, guid: String, limit: Int) -> JSONValue {
        let sorted = foods.values.sorted { ($0["updatedAt"]!.stringValue!, $0["guid"]!.stringValue!) < ($1["updatedAt"]!.stringValue!, $1["guid"]!.stringValue!) }
            .filter { ($0["updatedAt"]!.stringValue!, $0["guid"]!.stringValue!) > (updatedAt, guid) }
        let page = Array(sorted.prefix(limit))
        return .object([
            "foods": .array(page.map(JSONValue.object)),
            "lastPage": .bool(sorted.count <= limit),
            "lastUpdatedAt": page.last?["updatedAt"] ?? .null,
            "lastGuid": page.last?["guid"] ?? .null,
        ])
    }

    fileprivate func graph(from: String, to: String) -> JSONValue {
        func entries(_ kind: String) -> JSONValue {
            let manual = liveInsulins.filter { $0["insulinType"]?.stringValue == kind }.map { item -> JSONValue in
                .object(["timestamp": item["timestamp"]!, "value": item["value"]!, "delivered": .bool(false), "deviceName": .null])
            }
            let pen = penDoses.filter { $0.kind == kind }.map { dose -> JSONValue in
                .object(["timestamp": .string(dose.timestamp), "value": .double(dose.units), "delivered": .bool(true), "deviceName": .string("NovoPen 6")])
            }
            return .array((manual + pen).filter {
                guard case .object(let fields) = $0, let timestamp = fields["timestamp"]?.stringValue else { return false }
                return timestamp >= from && timestamp <= to
            })
        }
        return .object(["series": .object(["gkInsulinBolus": entries("bolus"), "gkInsulinBasal": entries("basal")])])
    }
}

/// Runs the fake on a real port and hands its sign-in URL to `body`.
func withFakeGlooko<Value: Sendable>(_ fake: FakeGlooko, _ body: @Sendable @escaping (URL) async throws -> Value) async throws -> Value {
    let router = Router()
    router.get("users/sign_in") { _, _ in
        var response = html(#"<html><head><meta name="csrf-token" content="token-123"></head><form></form></html>"#)
        response.headers[.setCookie] = "_logbook-web_session=anonymous; path=/"
        return response
    }
    router.post("users/sign_in") { request, context in
        let form = String(buffer: try await request.body.collect(upTo: 10_000))
        let fields = Dictionary(form.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }) { $1 }
        guard fields["authenticity_token"] == "token-123",
              let session = await fake.signIn(email: fields["user[email]"], password: fields["user[password]"])
        else { return html(#"<html><meta name="csrf-token" content="token-123"><p>Invalid email or password</p></html>"#) }
        var response = Response(status: .found)
        response.headers[.location] = "/dashboard"
        response.headers[.setCookie] = "_logbook-web_session=\(session); path=/; HttpOnly"
        return response
    }
    router.get("dashboard") { request, _ in
        guard await fake.authorized(request.headers[.cookie]) else {
            var response = Response(status: .found)
            response.headers[.location] = "/users/sign_in"
            return response
        }
        let host = request.head.authority ?? "localhost"
        return html("<script>window.patient = \"patient-1\"; config = { apiUrl: 'http://\(host)' }</script>")
    }
    for collection in ["foods", "insulins"] {
        router.put("api/v2/\(collection)") { request, _ in
            guard request.uri.queryParameters["patient"] == "patient-1" else { return json(400, #"{"error":"patient"}"#) }
            guard await fake.authorized(request.headers[.cookie]) else { return json(421, #"{"success":false}"#) }
            let body = try await request.body.collect(upTo: 1_000_000)
            guard case .object(let envelope) = try JSONDecoder().decode(JSONValue.self, from: Data(buffer: body)),
                  case .array(let items)? = envelope[collection]
            else { return json(422, #"{"error":"param is missing"}"#) }
            let result = await fake.write(collection: collection, items: items)
            return json(result.status, result.body)
        }
    }
    router.get("api/v2/foods") { request, _ in
        guard await fake.authorized(request.headers[.cookie]) else { return json(421, #"{"success":false}"#) }
        let query = request.uri.queryParameters
        guard let updatedAt = query["lastUpdatedAt"], let guid = query["lastGuid"] else { return json(422, "{}") }
        let page = await fake.feed(after: String(updatedAt), guid: String(guid), limit: Int(query["limit"] ?? "100") ?? 100)
        return json(200, String(decoding: try JSONEncoder().encode(page), as: UTF8.self))
    }
    router.get("api/v3/graph/data") { request, _ in
        guard await fake.authorized(request.headers[.cookie]) else { return json(421, #"{"success":false}"#) }
        let query = request.uri.queryParameters
        let graph = await fake.graph(from: String(query["startDate"] ?? ""), to: String(query["endDate"] ?? ""))
        return json(200, String(decoding: try JSONEncoder().encode(graph), as: UTF8.self))
    }
    let app = Application(router: router, logger: testLogger)
    return try await app.test(.live) { client in
        try await body(URL(string: "http://localhost:\(client.port!)/users/sign_in")!)
    }
}

private func html(_ text: String) -> Response {
    Response(status: .ok, headers: [.contentType: "text/html"], body: .init(byteBuffer: ByteBuffer(string: text)))
}

private func json(_ status: Int, _ text: String) -> Response {
    Response(status: .init(code: status), headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(string: text)))
}
