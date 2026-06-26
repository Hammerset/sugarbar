import Foundation

public struct Credentials: Equatable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public extension Credentials {
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Credentials? {
        guard
            let email = environment["SUGARBAR_LIBRE_EMAIL"],
            let password = environment["SUGARBAR_LIBRE_PASSWORD"]
        else { return nil }
        return Credentials(email: email, password: password)
    }
}

public protocol CredentialStore: Sendable {
    func loadCredentials() throws -> Credentials?
    func saveCredentials(_ credentials: Credentials) throws
    func clearCredentials() throws
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func clearToken() throws
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: Credentials?
    private var token: String?

    public init() {}

    public func loadCredentials() throws -> Credentials? {
        lock.withLock { credentials }
    }

    public func saveCredentials(_ credentials: Credentials) throws {
        lock.withLock { self.credentials = credentials }
    }

    public func clearCredentials() throws {
        lock.withLock { credentials = nil }
    }

    public func loadToken() throws -> String? {
        lock.withLock { token }
    }

    public func saveToken(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    public func clearToken() throws {
        lock.withLock { token = nil }
    }
}
