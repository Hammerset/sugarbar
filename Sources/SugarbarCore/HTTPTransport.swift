import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    /// Where the response actually came from, after any redirects.
    public let url: URL?

    public init(status: Int, body: Data, url: URL? = nil) {
        self.status = status
        self.body = body
        self.url = url
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(status: status, body: data, url: response.url)
    }
}
