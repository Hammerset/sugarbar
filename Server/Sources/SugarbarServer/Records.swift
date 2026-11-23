import Foundation
import Logging
import PostgresNIO

struct RecordBatch {
    var kinds: [String] = []
    var ids: [String] = []
    var times: [Date] = []
    var deleted: [Bool] = []
    var payloads: [String] = []

    var isEmpty: Bool { kinds.isEmpty }

    mutating func append(kind: String, id: String, updatedAt: Date, deleted isDeleted: Bool, payload: JSONValue) throws {
        kinds.append(kind)
        ids.append(id)
        times.append(updatedAt)
        deleted.append(isDeleted)
        payloads.append(String(decoding: try JSONEncoder().encode(isDeleted ? JSONValue.object([:]) : payload), as: UTF8.self))
    }
}

enum Records {
    static let lock: Int32 = 1

    /// Latest `updatedAt` wins; an equal one keeps the stored record. Must run inside a transaction.
    /// The server's own writes always land, at least a millisecond after the stored copy, so two
    /// writes in one tick both reach the devices.
    static func store(_ batch: RecordBatch, accountId: Int64, on connection: PostgresConnection, logger: Logger, serverWrite: Bool = false) async throws {
        guard !batch.isEmpty else { return }
        // Writers for one account take turns until commit, so seqs become visible in
        // the order they were handed out and a cursor can never pass an uncommitted one.
        try await connection.query(
            "SELECT pg_advisory_xact_lock(\(lock), \(Int32(truncatingIfNeeded: accountId)))",
            logger: logger
        )
        if serverWrite {
            try await connection.query(
                """
                INSERT INTO records (account_id, kind, id, updated_at, deleted, payload, seq)
                SELECT \(accountId), kind, id, updated_at, deleted, payload::jsonb, nextval('records_seq')
                FROM (
                    SELECT DISTINCT ON (kind, id) kind, id, updated_at, deleted, payload
                    FROM unnest(\(batch.kinds)::text[], \(batch.ids)::text[], \(batch.times)::timestamptz[], \(batch.deleted)::boolean[], \(batch.payloads)::text[])
                        WITH ORDINALITY AS c(kind, id, updated_at, deleted, payload, position)
                    ORDER BY kind, id, position DESC
                ) latest
                ON CONFLICT (account_id, kind, id) DO UPDATE
                SET updated_at = greatest(excluded.updated_at, records.updated_at + interval '1 millisecond'),
                    deleted = excluded.deleted, payload = excluded.payload, seq = excluded.seq
                """,
                logger: logger
            )
            return
        }
        try await connection.query(
            """
            WITH incoming AS (
                SELECT DISTINCT ON (kind, id) kind, id, updated_at, deleted, payload
                FROM unnest(\(batch.kinds)::text[], \(batch.ids)::text[], \(batch.times)::timestamptz[], \(batch.deleted)::boolean[], \(batch.payloads)::text[])
                    AS c(kind, id, updated_at, deleted, payload)
                ORDER BY kind, id, updated_at DESC
            ), accepted AS (
                SELECT i.* FROM incoming i
                LEFT JOIN records r ON r.account_id = \(accountId) AND r.kind = i.kind AND r.id = i.id
                WHERE r.id IS NULL OR i.updated_at > r.updated_at
            )
            INSERT INTO records (account_id, kind, id, updated_at, deleted, payload, seq)
            SELECT \(accountId), kind, id, updated_at, deleted, payload::jsonb, nextval('records_seq')
            FROM accepted
            ON CONFLICT (account_id, kind, id) DO UPDATE
            SET updated_at = excluded.updated_at, deleted = excluded.deleted,
                payload = excluded.payload, seq = excluded.seq
            WHERE excluded.updated_at > records.updated_at
            """,
            logger: logger
        )
    }
}
