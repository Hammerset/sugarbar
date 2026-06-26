public enum LibreLinkUpError: Error, Equatable, Sendable {
    case termsNotAccepted
    case authenticationFailed
    case noConnections
    case rateLimited
    case httpError(status: Int)
    case unexpectedResponse
}
