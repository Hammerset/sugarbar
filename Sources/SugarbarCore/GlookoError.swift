public enum GlookoError: Error, Equatable, Sendable {
    case authenticationFailed
    case sessionExpired
    case rateLimited
    case httpError(status: Int)
    case unexpectedResponse
}
