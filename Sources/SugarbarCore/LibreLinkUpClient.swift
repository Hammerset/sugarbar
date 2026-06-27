import Foundation

public let defaultLLUVersion = "4.16.0"
public let defaultLLURegion = "eu"

public actor LibreLinkUpClient {
    private let transport: HTTPTransport
    private let appVersion: String

    public init(transport: HTTPTransport, appVersion: String = defaultLLUVersion) {
        self.transport = transport
        self.appVersion = appVersion
    }

    public func fetchLatestReading(email: String, password: String) async throws -> Reading {
        try await fetchGraph(email: email, password: password).latest
    }

    public func connections(email: String, password: String) async throws -> [Connection] {
        let session = try await authenticate(email: email, password: password)
        return try await fetchConnections(session)
    }

    public func fetchGraph(
        email: String,
        password: String,
        preferredPatientId: String? = nil
    ) async throws -> GraphSnapshot {
        let session = try await authenticate(email: email, password: password)
        let connections = try await fetchConnections(session)
        guard let patient = selectedConnection(from: connections, preferredPatientId: preferredPatientId) else {
            throw LibreLinkUpError.noConnections
        }
        return try await fetchGraph(session, patientId: patient.patientId)
    }

    struct Session: Sendable {
        let token: String
        let accountId: String
        let region: String
    }

    func authenticate(email: String, password: String) async throws -> Session {
        switch try await login(email: email, password: password, region: defaultLLURegion) {
        case let .success(token, userId):
            return Session(token: token, accountId: accountIdHeader(forUserId: userId), region: defaultLLURegion)
        case let .redirect(region):
            guard case let .success(token, userId) =
                try await login(email: email, password: password, region: region)
            else {
                throw LibreLinkUpError.unexpectedResponse
            }
            return Session(token: token, accountId: accountIdHeader(forUserId: userId), region: region)
        }
    }

    private func login(email: String, password: String, region: String) async throws -> LoginResult {
        var request = makeRequest(region: region, path: "/llu/auth/login")
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])
        let response = try await send(request)
        return try decodeLogin(response.body)
    }

    private func fetchConnections(_ session: Session) async throws -> [Connection] {
        let request = authedRequest(session, path: "/llu/connections")
        let response = try await send(request)
        return try decodeConnections(response.body)
    }

    private func fetchGraph(_ session: Session, patientId: String) async throws -> GraphSnapshot {
        let request = authedRequest(session, path: "/llu/connections/\(patientId)/graph")
        let response = try await send(request)
        return try decodeGraph(response.body)
    }

    private func send(_ request: URLRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        switch response.status {
        case 200...299:
            return response
        case 429, 430:
            throw LibreLinkUpError.rateLimited
        default:
            throw LibreLinkUpError.httpError(status: response.status)
        }
    }

    private func makeRequest(region: String, path: String) -> URLRequest {
        let url = URL(string: "https://api-\(region).libreview.io\(path)")!
        var request = URLRequest(url: url)
        request.setValue("llu.android", forHTTPHeaderField: "product")
        request.setValue(appVersion, forHTTPHeaderField: "version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func authedRequest(_ session: Session, path: String) -> URLRequest {
        var request = makeRequest(region: session.region, path: path)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        request.setValue(session.accountId, forHTTPHeaderField: "account-id")
        return request
    }
}
