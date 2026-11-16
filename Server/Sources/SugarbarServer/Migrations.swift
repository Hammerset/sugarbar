import Logging
import PostgresNIO

enum Migrations {
    static let all: [(version: Int, statements: [PostgresQuery])] = [
        (1, [
            """
            CREATE TABLE accounts (
                id bigserial PRIMARY KEY,
                name text NOT NULL UNIQUE,
                created_at timestamptz NOT NULL DEFAULT now()
            )
            """,
            """
            CREATE TABLE tokens (
                token_hash text PRIMARY KEY,
                account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                created_at timestamptz NOT NULL DEFAULT now()
            )
            """,
            "CREATE INDEX tokens_account_id ON tokens (account_id)",
            "CREATE SEQUENCE records_seq AS bigint",
            """
            CREATE TABLE records (
                account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                kind text NOT NULL,
                id text NOT NULL,
                updated_at timestamptz NOT NULL,
                deleted boolean NOT NULL,
                payload jsonb NOT NULL,
                seq bigint NOT NULL,
                PRIMARY KEY (account_id, kind, id)
            )
            """,
            "CREATE INDEX records_account_seq ON records (account_id, seq)",
            """
            CREATE TABLE readings (
                account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                t bigint NOT NULL,
                value double precision NOT NULL,
                trend smallint NOT NULL,
                PRIMARY KEY (account_id, t)
            )
            """,
            """
            CREATE TABLE doses (
                account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                id text NOT NULL,
                t bigint NOT NULL,
                payload jsonb NOT NULL,
                PRIMARY KEY (account_id, id)
            )
            """,
            "CREATE INDEX doses_account_t ON doses (account_id, t)",
        ]),
    ]

    /// Applies pending migrations in one transaction; the advisory lock lets several
    /// instances start against the same database at once.
    static func run(on client: PostgresClient, logger: Logger) async throws {
        try await client.withTransaction(logger: logger) { connection in
            try await connection.query("SELECT pg_advisory_xact_lock(0, 0)", logger: logger)
            try await connection.query(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version integer PRIMARY KEY,
                    applied_at timestamptz NOT NULL DEFAULT now()
                )
                """,
                logger: logger
            )
            var applied = Set<Int>()
            for try await version in try await connection.query(
                "SELECT version FROM schema_migrations", logger: logger
            ).decode(Int.self) {
                applied.insert(version)
            }
            for migration in all where !applied.contains(migration.version) {
                for statement in migration.statements {
                    try await connection.query(statement, logger: logger)
                }
                try await connection.query(
                    "INSERT INTO schema_migrations (version) VALUES (\(migration.version))",
                    logger: logger
                )
                logger.info("applied migration", metadata: ["version": "\(migration.version)"])
            }
        }
    }
}
