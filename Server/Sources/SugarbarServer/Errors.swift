import Foundation
import Hummingbird
import NIOCore

public struct APIError: HTTPResponseError {
    public let status: HTTPResponse.Status
    public let message: String

    public init(_ status: HTTPResponse.Status, _ message: String) {
        self.status = status
        self.message = message
    }

    static func badRequest(_ message: String) -> APIError { APIError(.badRequest, message) }
    static let unauthorized = APIError(.unauthorized, "unauthorized")

    public func response(from request: Request, context: some RequestContext) throws -> Response {
        let body = try JSONEncoder().encode(["error": message])
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: body))
        )
    }
}

/// Turns every failure into the contract's `{"error": …}` shape. Database and other internal
/// errors are reported as a bare 500 so nothing from a query (medical data) reaches the client or the log.
struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            let apiError: APIError
            switch error {
            case let error as APIError:
                apiError = error
            case is NIOTooManyBytesError:
                apiError = APIError(.contentTooLarge, "request body is larger than 2 MB")
            case let error as HTTPError:
                apiError = APIError(error.status, error.body ?? error.status.reasonPhrase)
            default:
                context.logger.error("request failed", metadata: ["error.type": "\(type(of: error))"])
                apiError = APIError(.internalServerError, "internal error")
            }
            return try apiError.response(from: request, context: context)
        }
    }
}
