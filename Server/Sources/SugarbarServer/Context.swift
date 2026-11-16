import Foundation
import Hummingbird
import Logging
import PostgresNIO
import Synchronization

public struct AppContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    /// Shared with the outer logging middleware, which sees only its own copy of the context.
    let account = AccountSlot()

    public init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
    }

    public var maxUploadSize: Int { 2 * 1024 * 1024 }

    var accountId: Int64 {
        get throws {
            guard let id = account.id else { throw APIError.unauthorized }
            return id
        }
    }
}

final class AccountSlot: Sendable {
    private let value = Mutex<Int64?>(nil)
    var id: Int64? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// Logs one line per request: method, path, status, duration and account id. Never bodies,
/// query strings or headers, so no glucose data or tokens end up in logs.
struct RequestLogMiddleware: RouterMiddleware {
    let logger: Logger

    func handle(_ request: Request, context: AppContext, next: (Request, AppContext) async throws -> Response) async throws -> Response {
        let start = ContinuousClock.now
        let response = try await next(request, context)
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        var metadata: Logger.Metadata = [
            "method": "\(request.method.rawValue)",
            "path": "\(request.uri.path)",
            "status": "\(response.status.code)",
            "ms": "\(String(format: "%.1f", milliseconds))",
        ]
        if let account = context.account.id { metadata["account"] = "\(account)" }
        logger.info("request", metadata: metadata)
        return response
    }
}

struct AuthMiddleware: RouterMiddleware {
    let db: PostgresClient

    func handle(_ request: Request, context: AppContext, next: (Request, AppContext) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization],
              header.lowercased().hasPrefix("bearer ")
        else { throw APIError.unauthorized }
        let token = header.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { throw APIError.unauthorized }
        let hash = Tokens.hash(token)
        let rows = try await db.query("SELECT account_id FROM tokens WHERE token_hash = \(hash)")
        var accountId: Int64?
        for try await id in rows.decode(Int64.self) { accountId = id }
        guard let accountId else { throw APIError.unauthorized }
        context.account.id = accountId
        return try await next(request, context)
    }
}
