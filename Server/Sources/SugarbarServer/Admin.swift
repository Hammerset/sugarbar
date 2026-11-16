import Foundation
import Logging
import PostgresNIO

public enum AdminCommand {
    case createAccount(name: String)
    case createToken(account: String)
    case listAccounts
    case revokeTokens(account: String)

    public static let usage = """
        usage: sugarbar-server [serve]
               sugarbar-server create-account <name>   create an account and print its token
               sugarbar-server create-token <name>     print a new extra token for an account
               sugarbar-server list-accounts
               sugarbar-server revoke-token <name>     revoke every token of an account
        """

    public init?(arguments: [String]) {
        switch (arguments.first, arguments.count) {
        case ("create-account", 2): self = .createAccount(name: arguments[1])
        case ("create-token", 2): self = .createToken(account: arguments[1])
        case ("list-accounts", 1): self = .listAccounts
        case ("revoke-token", 2): self = .revokeTokens(account: arguments[1])
        default: return nil
        }
    }

    /// Runs against `DATABASE_URL`, applying migrations first, and returns what to print.
    public func run(_ configuration: ServerConfiguration, logger: Logger) async throws -> String {
        let db = PostgresClient(configuration: try postgresConfiguration(url: configuration.databaseURL), backgroundLogger: logger)
        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await db.run() }
            defer { group.cancelAll() }
            try await Migrations.run(on: db, logger: logger)
            return try await execute(db: db, logger: logger)
        }
    }

    private func execute(db: PostgresClient, logger: Logger) async throws -> String {
        switch self {
        case .createAccount(let name):
            return try await db.withTransaction(logger: logger) { connection in
                var accountId: Int64?
                for try await id in try await connection.query(
                    "INSERT INTO accounts (name) VALUES (\(name)) ON CONFLICT (name) DO NOTHING RETURNING id",
                    logger: logger
                ).decode(Int64.self) {
                    accountId = id
                }
                guard let accountId else { throw ConfigurationError.invalid("account \(name) already exists") }
                let token = Tokens.generate()
                try await connection.query(
                    "INSERT INTO tokens (token_hash, account_id) VALUES (\(Tokens.hash(token)), \(accountId))",
                    logger: logger
                )
                return Self.tokenMessage(account: name, token: token)
            }
        case .createToken(let name):
            let accountId = try await Self.accountId(name, db: db, logger: logger)
            let token = Tokens.generate()
            try await db.query("INSERT INTO tokens (token_hash, account_id) VALUES (\(Tokens.hash(token)), \(accountId))", logger: logger)
            return Self.tokenMessage(account: name, token: token)
        case .listAccounts:
            var lines = ["id\tname\ttokens\tcreated_at"]
            for try await (id, name, tokens, created) in try await db.query(
                """
                SELECT a.id, a.name, count(t.token_hash), a.created_at
                FROM accounts a LEFT JOIN tokens t ON t.account_id = a.id
                GROUP BY a.id ORDER BY a.id
                """,
                logger: logger
            ).decode((Int64, String, Int64, Date).self) {
                lines.append("\(id)\t\(name)\t\(tokens)\t\(Timestamps.format(created))")
            }
            return lines.joined(separator: "\n")
        case .revokeTokens(let name):
            let accountId = try await Self.accountId(name, db: db, logger: logger)
            var revoked = 0
            for try await _ in try await db.query(
                "DELETE FROM tokens WHERE account_id = \(accountId) RETURNING 1", logger: logger
            ).decode(Int32.self) {
                revoked += 1
            }
            return "revoked \(revoked) token(s) of \(name)"
        }
    }

    private static func accountId(_ name: String, db: PostgresClient, logger: Logger) async throws -> Int64 {
        for try await id in try await db.query("SELECT id FROM accounts WHERE name = \(name)", logger: logger).decode(Int64.self) {
            return id
        }
        throw ConfigurationError.invalid("no account named \(name)")
    }

    private static func tokenMessage(account: String, token: String) -> String {
        "token for \(account) (shown once, store it now):\n\(token)"
    }
}
