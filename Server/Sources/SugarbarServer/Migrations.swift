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
        (2, [
            """
            CREATE TABLE glooko_state (
                account_id bigint PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                records_cursor bigint NOT NULL,
                push_from timestamptz NOT NULL,
                feed_updated_at text NOT NULL,
                feed_guid text NOT NULL,
                paused_reason text,
                paused_settings_at timestamptz,
                retry_at timestamptz,
                failures integer NOT NULL DEFAULT 0,
                summary_fingerprint text
            )
            """,
            """
            CREATE TABLE glooko_links (
                account_id bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                source_kind text NOT NULL,
                source_id text NOT NULL,
                collection text NOT NULL,
                glooko_guid text NOT NULL,
                origin text NOT NULL,
                desired jsonb NOT NULL,
                desired_fingerprint text NOT NULL,
                pushed_fingerprint text,
                remote_fingerprint text,
                written boolean NOT NULL,
                status text NOT NULL,
                last_error text,
                attempts integer NOT NULL,
                next_attempt_at timestamptz NOT NULL,
                event_at timestamptz NOT NULL,
                removal_reason text,
                superseded_by text,
                echoes jsonb NOT NULL,
                status_fingerprint text,
                PRIMARY KEY (account_id, source_kind, source_id),
                UNIQUE (account_id, collection, glooko_guid)
            )
            """,
            "CREATE INDEX glooko_links_due ON glooko_links (account_id, next_attempt_at)",
        ]),
        (3, [
            "ALTER TABLE doses ADD COLUMN deleted boolean NOT NULL DEFAULT false",
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
