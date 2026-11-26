import Foundation
import Hummingbird
import PostgresNIO

/// A deleted Dose is kept as a tombstone with an empty payload, so every device learns of the deletion
/// and apps that predate tombstones skip it rather than store an empty Dose.
struct Dose: Codable {
    let id: String
    let t: Int64
    let payload: JSONValue
    let deleted: Bool?

    init(id: String, t: Int64, payload: JSONValue, deleted: Bool) {
        self.id = id
        self.t = t
        self.payload = deleted ? .object([:]) : payload
        self.deleted = deleted ? true : nil
    }

    var isDeleted: Bool { deleted == true }
}

struct DosesUpload: Decodable { let doses: [Dose] }
struct DosesPage: ResponseEncodable { let doses: [Dose]; let hasMore: Bool }

enum Doses {
    static func upload(request: Request, context: AppContext, db: PostgresClient) async throws -> StoredResponse {
        let accountId = try context.accountId
        let body = try await request.decode(as: DosesUpload.self, context: context)
        var latest: [String: Dose] = [:]
        for (index, dose) in body.doses.enumerated() {
            guard !dose.id.isEmpty else { throw APIError.badRequest("doses.\(index).id must not be empty") }
            guard dose.payload.isObject else { throw APIError.badRequest("doses.\(index).payload must be an object") }
            latest[dose.id] = dose
        }
        guard !latest.isEmpty else { return StoredResponse(stored: 0) }
        let doses = latest.values.map { Dose(id: $0.id, t: $0.t, payload: $0.payload, deleted: $0.isDeleted) }
        let encoder = JSONEncoder()
        let payloads = try doses.map { String(decoding: try encoder.encode($0.payload), as: UTF8.self) }
        try await db.query(
            """
            INSERT INTO doses (account_id, id, t, payload, deleted)
            SELECT \(accountId), id, t, payload::jsonb, deleted
            FROM unnest(\(doses.map(\.id))::text[], \(doses.map(\.t))::bigint[], \(payloads)::text[], \(doses.map(\.isDeleted))::boolean[])
                AS d(id, t, payload, deleted)
            ON CONFLICT (account_id, id) DO UPDATE SET t = excluded.t, payload = excluded.payload, deleted = excluded.deleted
            """,
            logger: context.logger
        )
        return StoredResponse(stored: doses.count)
    }

    static func list(request: Request, context: AppContext, db: PostgresClient) async throws -> DosesPage {
        let accountId = try context.accountId
        let page = try PageQuery(request)
        let lowerBound = max(page.from, (page.after ?? Int64.min) &+ 1)
        let rows = try await db.query(
            """
            SELECT id, t, payload::text, deleted FROM doses
            WHERE account_id = \(accountId) AND t >= \(lowerBound) AND t <= \(page.to)
            ORDER BY t, id
            LIMIT \(page.limit + 1)
            """,
            logger: context.logger
        )
        let decoder = JSONDecoder()
        var doses: [Dose] = []
        for try await (id, t, payload, deleted) in rows.decode((String, Int64, String, Bool).self) {
            doses.append(Dose(id: id, t: t, payload: try decoder.decode(JSONValue.self, from: Data(payload.utf8)), deleted: deleted))
        }
        var hasMore = doses.count > page.limit
        if hasMore {
            doses.removeLast()
            // `after` pages by t, so a page must not end part-way through Doses sharing one t.
            let lastT = doses.last!.t
            let trimmed = doses.filter { $0.t != lastT }
            if !trimmed.isEmpty { doses = trimmed }
            hasMore = true
        }
        return DosesPage(doses: doses, hasMore: hasMore)
    }
}
