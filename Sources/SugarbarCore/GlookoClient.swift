import Foundation

public let glookoSignInURL = URL(string: "https://my.glooko.com/users/sign_in?locale=en-GB")!

/// Glooko has no public API; this drives the web app's sign-in form and then calls the
/// JSON endpoints its dashboard uses. Cookies ride on the transport's URLSession.
public actor GlookoClient {
    private let transport: HTTPTransport
    private let timeZone: TimeZone
    private var cachedSession: (email: String, session: Session)?

    public init(transport: HTTPTransport, timeZone: TimeZone = .current) {
        self.transport = transport
        self.timeZone = timeZone
    }

    public func fetchDoses(email: String, password: String, from start: Date, to end: Date) async throws -> [InsulinDose] {
        try await withSession(email: email, password: password) { session in
            try await self.fetchDoses(session, from: start, to: end)
        }
    }

    struct Session: Sendable {
        let patientId: String
        let apiBase: URL
        let origin: URL
    }

    private func withSession<T>(
        email: String,
        password: String,
        _ operation: (Session) async throws -> T
    ) async throws -> T {
        let session = try await session(email: email, password: password)
        do {
            return try await operation(session)
        } catch GlookoError.sessionExpired {
            cachedSession = nil
            let freshSession = try await authenticate(email: email, password: password)
            cachedSession = (email, freshSession)
            return try await operation(freshSession)
        }
    }

    private func session(email: String, password: String) async throws -> Session {
        if let cachedSession, cachedSession.email == email {
            return cachedSession.session
        }
        let session = try await authenticate(email: email, password: password)
        cachedSession = (email, session)
        return session
    }

    func authenticate(email: String, password: String) async throws -> Session {
        let loginPage = try await send(pageRequest(glookoSignInURL))
        guard let token = parseCSRFToken(fromLoginPage: String(decoding: loginPage.body, as: UTF8.self)) else {
            throw GlookoError.unexpectedResponse
        }

        var request = pageRequest(loginPage.url ?? glookoSignInURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(glookoSignInURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = Data(formURLEncoded([
            ("authenticity_token", token),
            ("user[email]", email),
            ("user[password]", password),
            ("commit", "Log In"),
        ]).utf8)
        let response = try await send(request)
        guard let dashboard = parseDashboard(String(decoding: response.body, as: UTF8.self)) else {
            throw GlookoError.authenticationFailed
        }
        return Session(
            patientId: dashboard.patientId,
            apiBase: dashboard.apiBase,
            origin: origin(of: response.url) ?? dashboardOrigin(forAPIBase: dashboard.apiBase)
        )
    }

    private func fetchDoses(_ session: Session, from start: Date, to end: Date) async throws -> [InsulinDose] {
        var components = URLComponents(url: session.apiBase.appending(path: "api/v3/graph/data"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "patient", value: session.patientId),
            URLQueryItem(name: "startDate", value: formatGlookoTimestamp(start, timeZone: timeZone)),
            URLQueryItem(name: "endDate", value: formatGlookoTimestamp(end, timeZone: timeZone)),
            URLQueryItem(name: "locale", value: "en-GB"),
            URLQueryItem(name: "insulinTooltips", value: "true"),
            URLQueryItem(name: "filterBgReadings", value: "true"),
            URLQueryItem(name: "splitByDay", value: "false"),
            URLQueryItem(name: "series[]", value: "gkInsulinBolus"),
            URLQueryItem(name: "series[]", value: "gkInsulinBasal"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(session.origin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(session.origin.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        let response = try await send(request)
        // An expired cookie session bounces the JSON call to the HTML sign-in page with a 200.
        if response.body.first == UInt8(ascii: "<") { throw GlookoError.sessionExpired }
        return try decodeGlookoDoses(response.body, timeZone: timeZone)
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        switch response.status {
        case 200...299:
            return response
        case 401:
            throw GlookoError.sessionExpired
        case 429:
            throw GlookoError.rateLimited
        default:
            throw GlookoError.httpError(status: response.status)
        }
    }

    private func pageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        return request
    }

    private func origin(of url: URL?) -> URL? {
        guard let url, let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }

    private func dashboardOrigin(forAPIBase apiBase: URL) -> URL {
        let host = (apiBase.host() ?? "").replacingOccurrences(of: "api.glooko", with: "my.glooko")
        return URL(string: "https://\(host)")!
    }
}

private let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:148.0) Gecko/20100101 Firefox/148.0"

func formURLEncoded(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._*")
    return fields.map { name, value in
        let encode = { (s: String) in
            s.addingPercentEncoding(withAllowedCharacters: allowed)!.replacingOccurrences(of: "%20", with: "+")
        }
        return "\(encode(name))=\(encode(value))"
    }.joined(separator: "&")
}
