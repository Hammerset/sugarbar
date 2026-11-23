import Foundation
import Hummingbird
import PostgresNIO

struct SyncChange: Codable {
    let kind: String
    let id: String
    let updatedAt: String
    let deleted: Bool
    let payload: JSONValue?
    var seq: Int64?
}

struct SyncRequest: Decodable {
    let deviceId: String?
    let cursor: Int64
    let changes: [SyncChange]

    enum CodingKeys: String, CodingKey { case deviceId, cursor, changes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        cursor = try container.decodeIfPresent(Int64.self, forKey: .cursor) ?? 0
        changes = try container.decodeIfPresent([SyncChange].self, forKey: .changes) ?? []
    }
}

struct SyncResponse: ResponseEncodable {
    let cursor: Int64
    let hasMore: Bool
    let changes: [SyncChange]
}

enum Sync {
    static let pageSize = 500

    static func handle(request: Request, context: AppContext, db: PostgresClient) async throws -> SyncResponse {
        let accountId = try context.accountId
        let body = try await request.decode(as: SyncRequest.self, context: context)
        guard body.cursor >= 0 else { throw APIError.badRequest("cursor must not be negative") }

        var batch = RecordBatch()
        for (index, change) in body.changes.enumerated() {
            guard !change.kind.isEmpty, !change.id.isEmpty else {
                throw APIError.badRequest("changes.\(index): kind and id must not be empty")
            }
            guard let updatedAt = Timestamps.parse(change.updatedAt) else {
                throw APIError.badRequest("changes.\(index).updatedAt is not an ISO 8601 timestamp")
            }
            try batch.append(kind: change.kind, id: change.id, updatedAt: updatedAt, deleted: change.deleted, payload: change.payload ?? .object([:]))
        }

        return try await db.withTransaction(logger: context.logger) { connection in
            try await Records.store(
                batch,
                accountId: accountId,
                on: connection,
                logger: context.logger
            )
            let rows = try await connection.query(
                """
                SELECT seq, kind, id, updated_at, deleted, payload::text
                FROM records
                WHERE account_id = \(accountId) AND seq > \(body.cursor)
                ORDER BY seq
                LIMIT \(pageSize + 1)
                """,
                logger: context.logger
            )
            let decoder = JSONDecoder()
            var changes: [SyncChange] = []
            for try await (seq, kind, id, updatedAt, isDeleted, payload) in rows.decode((Int64, String, String, Date, Bool, String).self) {
                changes.append(SyncChange(
                    kind: kind,
                    id: id,
                    updatedAt: Timestamps.format(updatedAt),
                    deleted: isDeleted,
                    payload: try decoder.decode(JSONValue.self, from: Data(payload.utf8)),
                    seq: seq
                ))
            }
            let hasMore = changes.count > pageSize
            if hasMore { changes.removeLast() }
            return SyncResponse(cursor: changes.last?.seq ?? body.cursor, hasMore: hasMore, changes: changes)
        }
    }
}
