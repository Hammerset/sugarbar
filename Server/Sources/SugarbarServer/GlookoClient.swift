import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

public let glookoSignInURL = URL(string: "https://my.glooko.com/users/sign_in?locale=en-GB")!

public struct GlookoCredentials: Codable, Equatable, Sendable {
    public var email: String
    public var password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

enum GlookoError: Error, Equatable {
    case sessionExpired
    case signInFailed
    /// Glooko refused the item itself (422): retrying the same body cannot help.
    case rejected(String)
    /// Any other 4xx: something about how we call Glooko is wrong.
    case refused(Int)
    /// Network trouble, 5xx or 429: worth retrying later.
    case transient(String)
    case unexpected(String)

    var message: String {
        switch self {
        case .sessionExpired: "Glooko session expired"
        case .signInFailed: "Glooko sign-in failed; check the login on the server"
        case .rejected(let detail): "Glooko rejected it: \(detail)"
        case .refused(let status): "Glooko answered HTTP \(status)"
        case .transient(let detail): "Glooko unreachable: \(detail)"
        case .unexpected(let detail): "Unexpected answer from Glooko: \(detail)"
        }
    }
}

struct GlookoFeedCursor: Equatable, Sendable {
    var updatedAt: String
    var guid: String

    static func starting(at date: Date) -> Self {
        GlookoFeedCursor(updatedAt: Timestamps.format(date), guid: "00000000-0000-0000-0000-000000000000")
    }
}

struct GlookoFood: Decodable, Equatable, Sendable {
    let guid: String
    let timestamp: String?
    let name: String?
    let carbs: Double?
    let softDeleted: Bool?
    let updatedAt: String?
}

struct GlookoFoodsPage: Decodable, Sendable {
    let foods: [GlookoFood]
    let lastPage: Bool
    let lastUpdatedAt: String?
    let lastGuid: String?
}

/// One insulin entry from the web graph; `delivered` is true for doses a connected pen recorded.
struct GlookoGraphDose: Decodable, Equatable, Sendable {
    let timestamp: String?
    let value: Double?
    let delivered: Bool?
    let deviceName: String?

    var isFromPen: Bool { delivered == true || deviceName != nil }
}

struct GlookoGraphInsulin: Sendable {
    let bolus: [GlookoGraphDose]
    let basal: [GlookoGraphDose]
}

/// Glooko has no public API. This signs in through the web form and then uses the mobile app's
/// sync API (`/api/v2/…`) for writes and the web graph for pen doses, with the cookie session.
actor GlookoClient {
    private struct Session {
        let patientId: String
        let apiBase: URL
        let origin: String
    }

    private let credentials: GlookoCredentials
    private let signInURL: URL
    private let http: HTTPClient
    private var cookies: [String: String] = [:]
    private var session: Session?

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:148.0) Gecko/20100101 Firefox/148.0"

    init(credentials: GlookoCredentials, signInURL: URL, http: HTTPClient) {
        self.credentials = credentials
        self.signInURL = signInURL
        self.http = http
    }

    func put(collection: String, items: [JSONValue]) async throws {
        try await withSession { session in
            let body = try JSONEncoder().encode(JSONValue.object([collection: .array(items)]))
            let response = try await self.api(session, method: .PUT, path: "api/v2/\(collection)", query: [("patient", session.patientId)], body: body)
            switch response.status {
            case 200...204 where response.body.isEmpty:
                return
            case 200...299:
                throw GlookoError.unexpected("HTTP \(response.status) with a body to a write")
            case 422:
                throw GlookoError.rejected(Self.summary(of: response.body))
            default:
                throw Self.error(for: response.status)
            }
        }
    }

    func foods(after cursor: GlookoFeedCursor, limit: Int = 200) async throws -> GlookoFoodsPage {
        try await withSession { session in
            let response = try await self.api(session, method: .GET, path: "api/v2/foods", query: [
                ("patient", session.patientId),
                ("lastUpdatedAt", cursor.updatedAt),
                ("lastGuid", cursor.guid),
                ("limit", "\(limit)"),
            ])
            guard (200...299).contains(response.status) else { throw Self.error(for: response.status) }
            do {
                return try JSONDecoder().decode(GlookoFoodsPage.self, from: response.body)
            } catch {
                throw GlookoError.unexpected("the foods feed did not decode")
            }
        }
    }

    /// `from`/`to` are Glooko wall-clock strings.
    func graphInsulin(from: String, to: String) async throws -> GlookoGraphInsulin {
        struct Envelope: Decodable {
            struct Series: Decodable {
                let gkInsulinBolus: [GlookoGraphDose]?
                let gkInsulinBasal: [GlookoGraphDose]?
            }
            let series: Series
        }
        return try await withSession { session in
            let response = try await self.api(session, method: .GET, path: "api/v3/graph/data", query: [
                ("patient", session.patientId),
                ("startDate", from),
                ("endDate", to),
                ("locale", "en-GB"),
                ("insulinTooltips", "true"),
                ("filterBgReadings", "true"),
                ("splitByDay", "false"),
                ("series[]", "gkInsulinBolus"),
                ("series[]", "gkInsulinBasal"),
            ])
            guard (200...299).contains(response.status) else { throw Self.error(for: response.status) }
            do {
                let series = try JSONDecoder().decode(Envelope.self, from: response.body).series
                return GlookoGraphInsulin(bolus: series.gkInsulinBolus ?? [], basal: series.gkInsulinBasal ?? [])
            } catch {
                throw GlookoError.unexpected("the insulin graph did not decode")
            }
        }
    }

    private func withSession<T: Sendable>(_ operation: (Session) async throws -> T) async throws -> T {
        let current: Session
        if let session { current = session } else { current = try await signIn() }
        do {
            return try await operation(current)
        } catch GlookoError.sessionExpired {
            session = nil
            let fresh = try await signIn()
            do {
                return try await operation(fresh)
            } catch GlookoError.sessionExpired {
                session = nil
                throw GlookoError.unexpected("the session expired right after signing in")
            }
        }
    }

    private func signIn() async throws -> Session {
        cookies = [:]
        let loginPage = try await send(url: signInURL, method: .GET, headers: pageHeaders())
        guard (200...299).contains(loginPage.status) else { throw Self.error(for: loginPage.status) }
        guard let token = firstCapture(#"name="csrf-token" content="([^"]+)""#, in: String(decoding: loginPage.body, as: UTF8.self)) else {
            throw GlookoError.unexpected("no sign-in form")
        }
        var headers = pageHeaders()
        headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        headers.add(name: "Referer", value: signInURL.absoluteString)
        let form = formURLEncoded([
            ("authenticity_token", token),
            ("user[email]", credentials.email),
            ("user[password]", credentials.password),
            ("commit", "Log In"),
        ])
        let dashboard = try await send(url: loginPage.url, method: .POST, headers: headers, body: Data(form.utf8))
        let html = String(decoding: dashboard.body, as: UTF8.self)
        guard (200...299).contains(dashboard.status),
              let patientId = firstCapture(#"window\.patient\s*=\s*"([^"]+)""#, in: html),
              let apiString = firstCapture(#"apiUrl:\s*'([^']+)'"#, in: html),
              let apiBase = URL(string: apiString),
              let origin = Self.origin(of: dashboard.url)
        else { throw GlookoError.signInFailed }
        let session = Session(patientId: patientId, apiBase: apiBase, origin: origin)
        self.session = session
        return session
    }

    private func api(_ session: Session, method: HTTPMethod, path: String, query: [(String, String)], body: Data? = nil) async throws -> Response {
        var components = URLComponents(url: session.apiBase.appending(path: path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = formURLEncoded(query)
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "application/json, text/plain, */*")
        headers.add(name: "X-Requested-With", value: "XMLHttpRequest")
        headers.add(name: "Origin", value: session.origin)
        headers.add(name: "Referer", value: session.origin + "/")
        headers.add(name: "User-Agent", value: Self.userAgent)
        if body != nil { headers.add(name: "Content-Type", value: "application/json") }
        let response = try await send(url: components.url!, method: method, headers: headers, body: body, followRedirects: false)
        // Glooko answers an expired session with 421 (once with a 200 bounce to the sign-in page).
        if response.status == 401 || response.status == 421 || response.body.first == UInt8(ascii: "<") || (300...399).contains(response.status) {
            throw GlookoError.sessionExpired
        }
        return response
    }

    struct Response {
        let status: Int
        let body: Data
        let url: URL
    }

    /// Follows redirects by hand so cookies set along the way are kept.
    private func send(url: URL, method: HTTPMethod, headers: HTTPHeaders, body: Data? = nil, followRedirects: Bool = true) async throws -> Response {
        var url = url
        var method = method
        var body = body
        var headers = headers
        for _ in 0..<10 {
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = method
            request.headers = headers
            if !cookies.isEmpty {
                request.headers.replaceOrAdd(name: "Cookie", value: cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
            }
            if let body { request.body = .bytes(ByteBuffer(bytes: body)) }
            let response: HTTPClientResponse
            let data: Data
            do {
                response = try await http.execute(request, timeout: .seconds(30))
                data = Data(buffer: try await response.body.collect(upTo: 20 * 1024 * 1024))
            } catch {
                throw GlookoError.transient("\(type(of: error))")
            }
            for header in response.headers["Set-Cookie"] {
                guard let pair = header.split(separator: ";").first, let equals = pair.firstIndex(of: "=") else { continue }
                cookies[pair[..<equals].trimmingCharacters(in: .whitespaces)] = String(pair[pair.index(after: equals)...])
            }
            let status = Int(response.status.code)
            guard followRedirects, (300...399).contains(status),
                  let location = response.headers.first(name: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL
            else { return Response(status: status, body: data, url: url) }
            url = next
            if status != 307 && status != 308 {
                method = .GET
                body = nil
                headers.remove(name: "Content-Type")
            }
        }
        throw GlookoError.unexpected("too many redirects")
    }

    private func pageHeaders() -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(name: "User-Agent", value: Self.userAgent)
        headers.add(name: "Accept", value: "text/html,application/xhtml+xml")
        return headers
    }

    private static func error(for status: Int) -> GlookoError {
        switch status {
        case 429, 500...599: .transient("HTTP \(status)")
        case 400...499: .refused(status)
        default: .unexpected("HTTP \(status)")
        }
    }

    /// Glooko's 422 names the fields it refused; values are left out so no health data is logged.
    private static func summary(of body: Data) -> String {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: body) else { return "HTTP 422" }
        var fields: Set<String> = []
        func collect(_ value: JSONValue) {
            switch value {
            case .object(let object):
                if case .object(let errors)? = object["errors"] { fields.formUnion(errors.keys) }
                object.values.forEach(collect)
            case .array(let array): array.forEach(collect)
            default: break
            }
        }
        collect(json)
        return fields.isEmpty ? "HTTP 422" : "invalid " + fields.sorted().joined(separator: ", ")
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }
}

func formURLEncoded(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._*")
    let encode = { (text: String) in
        text.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+")
    }
    return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
}

private func firstCapture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}

/// Glooko's timestamps are the patient's wall-clock time with a literal "Z". The offset is the one
/// in force at that moment, so entries either side of a DST change keep their own local time.
struct GlookoWallClock: Sendable {
    let timeZone: TimeZone

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func format(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let whole = Date(timeIntervalSince1970: (milliseconds / 1000).rounded(.down))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!,
            Int(milliseconds - whole.timeIntervalSince1970 * 1000)
        )
    }

    func parse(_ text: String) -> Date? {
        guard let wallClock = Timestamps.parse(text) else { return nil }
        var parts = Self.utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: wallClock)
        parts.timeZone = timeZone
        return calendar.date(from: parts)
    }

    func clockTime(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour!, parts.minute!)
    }
}
