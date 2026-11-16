import Foundation
import NIOSSL
import PostgresNIO

public enum ConfigurationError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .missing(let name): "\(name) is not set"
        case .invalid(let message): message
        }
    }
}

/// Parses a libpq-style URL: `postgres://user:password@host:5432/db?sslmode=require`.
/// `sslmode` is `disable`, `prefer` (default), `require` (encrypted, certificate not checked)
/// or `verify-full`. `?host=/cloudsql/<instance>` connects over a Unix socket.
public func postgresConfiguration(url string: String) throws -> PostgresClient.Configuration {
    guard let components = URLComponents(string: string),
          components.scheme == "postgres" || components.scheme == "postgresql"
    else { throw ConfigurationError.invalid("DATABASE_URL must start with postgres://") }

    let query = Dictionary(
        (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { _, last in last }
    )
    guard let username = components.user, !username.isEmpty else {
        throw ConfigurationError.invalid("DATABASE_URL has no user")
    }
    let password = components.password
    let path = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
    let database = path.isEmpty ? nil : path

    if let socketDirectory = query["host"], socketDirectory.hasPrefix("/") {
        let port = components.port ?? 5432
        return PostgresClient.Configuration(
            unixSocketPath: "\(socketDirectory)/.s.PGSQL.\(port)",
            username: username,
            password: password,
            database: database
        )
    }

    guard let host = components.host, !host.isEmpty else {
        throw ConfigurationError.invalid("DATABASE_URL has no host")
    }
    let tls: PostgresClient.Configuration.TLS
    switch query["sslmode"] ?? "prefer" {
    case "disable":
        tls = .disable
    case "prefer", "allow":
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .none
        tls = .prefer(tlsConfiguration)
    case "require":
        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .none
        tls = .require(tlsConfiguration)
    case "verify-ca", "verify-full":
        tls = .require(.makeClientConfiguration())
    case let other:
        throw ConfigurationError.invalid("unsupported sslmode \(other)")
    }
    return PostgresClient.Configuration(
        host: host,
        port: components.port ?? 5432,
        username: username,
        password: password,
        database: database,
        tls: tls
    )
}
