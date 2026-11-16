import Foundation
import Hummingbird
import PostgresNIO

struct Dose: Codable {
    let id: String
    let t: Int64
    let payload: JSONValue
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
        let doses = Array(latest.values)
        let encoder = JSONEncoder()
        let payloads = try doses.map { String(decoding: try encoder.encode($0.payload), as: UTF8.self) }
        try await db.query(
            """
            INSERT INTO doses (account_id, id, t, payload)
            SELECT \(accountId), id, t, payload::jsonb
            FROM unnest(\(doses.map(\.id))::text[], \(doses.map(\.t))::bigint[], \(payloads)::text[]) AS d(id, t, payload)
            ON CONFLICT (account_id, id) DO UPDATE SET t = excluded.t, payload = excluded.payload
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
            SELECT id, t, payload::text FROM doses
            WHERE account_id = \(accountId) AND t >= \(lowerBound) AND t <= \(page.to)
            ORDER BY t, id
            LIMIT \(page.limit + 1)
            """,
            logger: context.logger
        )
        let decoder = JSONDecoder()
        var doses: [Dose] = []
        for try await (id, t, payload) in rows.decode((String, Int64, String).self) {
            doses.append(Dose(id: id, t: t, payload: try decoder.decode(JSONValue.self, from: Data(payload.utf8))))
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
