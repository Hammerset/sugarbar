import Foundation

public struct SyncConfiguration: Equatable, Sendable {
    public let serverURL: URL
    public let token: String

    public init(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    /// Nil unless the text is an http(s) address with a host.
    public static func serverURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }
}

public enum SyncError: Error, Equatable, Sendable {
    case unauthorized
    case payloadTooLarge
    case server(status: Int, message: String?)
    case invalidResponse
}

extension SyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The Sync Server did not accept the access token."
        case .payloadTooLarge: "The Sync Server refused a request as too large."
        case let .server(status, message): "The Sync Server answered \(status)\(message.map { ": \($0)" } ?? "")."
        case .invalidResponse: "The Sync Server sent a response sugarbar does not understand."
        }
    }
}

/// The wire contract of issue #47, v1. Knows nothing about local stores.
public struct SyncClient: Sendable {
    public static let maximumBodyBytes = 2_000_000
    public static let pageLimit = 5000

    private let configuration: SyncConfiguration
    private let transport: HTTPTransport

    public init(configuration: SyncConfiguration, transport: HTTPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func sync(_ request: SyncRequest) async throws -> SyncResponse {
        try await send("POST", "v1/sync", body: request)
    }

    public func upload(readings: [WireReading]) async throws {
        let _: StoredCount = try await send("POST", "v1/readings", body: ReadingsBody(readings: readings, hasMore: nil))
    }

    public func readings(from: Int, to: Int, after: Int?) async throws -> ReadingsBody {
        try await send("GET", "v1/readings", query: range(from: from, to: to, after: after))
    }

    public func upload(doses: [WireDose]) async throws {
        let _: StoredCount = try await send("POST", "v1/doses", body: DosesBody(doses: doses, hasMore: nil))
    }

    public func doses(from: Int, to: Int, after: Int?) async throws -> DosesBody {
        try await send("GET", "v1/doses", query: range(from: from, to: to, after: after))
    }

    private struct StoredCount: Decodable {}

    private struct Empty: Encodable {}

    private func range(from: Int, to: Int, after: Int?) -> [URLQueryItem] {
        [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "to", value: String(to)),
            URLQueryItem(name: "limit", value: String(Self.pageLimit)),
        ] + (after.map { [URLQueryItem(name: "after", value: String($0))] } ?? [])
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        try await send(method, path, query: query, body: Empty?.none)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Body?
    ) async throws -> Response {
        var url = configuration.serverURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await transport.send(request)
        switch response.status {
        case 200..<300:
            do {
                return try JSONDecoder().decode(Response.self, from: response.body)
            } catch {
                throw SyncError.invalidResponse
            }
        case 401: throw SyncError.unauthorized
        case 413: throw SyncError.payloadTooLarge
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: response.body))?["error"]
            throw SyncError.server(status: response.status, message: message)
        }
    }
}
