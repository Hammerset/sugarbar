import Foundation
import Hummingbird
import PostgresNIO

struct Reading: Codable, Equatable {
    let t: Int64
    let v: Double
    let trend: Int16

    enum CodingKeys: String, CodingKey { case t, v, trend }

    init(t: Int64, v: Double, trend: Int16) {
        self.t = t
        self.v = v
        self.trend = trend
    }

    /// A missing trend is LibreLinkUp's 0, "not determined" (backfilled Readings carry none).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        t = try container.decode(Int64.self, forKey: .t)
        v = try container.decode(Double.self, forKey: .v)
        trend = try container.decodeIfPresent(Int16.self, forKey: .trend) ?? 0
    }
}

struct ReadingsUpload: Decodable { let readings: [Reading] }
struct StoredResponse: ResponseEncodable { let stored: Int }
struct ReadingsPage: ResponseEncodable { let readings: [Reading]; let hasMore: Bool }

struct PageQuery {
    static let maxLimit = 5000
    let from: Int64
    let to: Int64
    let after: Int64?
    let limit: Int

    init(_ request: Request) throws {
        let query = request.uri.queryParameters
        func number(_ name: String) throws -> Int64? {
            guard let raw = query[Substring(name)] else { return nil }
            guard let value = Int64(raw) else { throw APIError.badRequest("\(name) must be an integer") }
            return value
        }
        from = try number("from") ?? 0
        to = try number("to") ?? Int64.max
        after = try number("after")
        let limit = try number("limit") ?? Int64(Self.maxLimit)
        guard limit > 0 else { throw APIError.badRequest("limit must be positive") }
        self.limit = Int(min(limit, Int64(Self.maxLimit)))
    }
}

enum Readings {
    static let dedupWindow: Int64 = 30
    static let readingsLock: Int32 = 2

    /// Keeps each incoming Reading (oldest first) unless one already stored, or one kept
    /// earlier in this batch, lies within 30 s of it. `stored` must be sorted ascending.
    static func newReadings(_ incoming: [Reading], stored: [Int64]) -> [Reading] {
        var kept: [Reading] = []
        var storedIndex = 0
        for reading in incoming.sorted(by: { $0.t < $1.t }) {
            while storedIndex < stored.count, stored[storedIndex] < reading.t - dedupWindow {
                storedIndex += 1
            }
            if storedIndex < stored.count, stored[storedIndex] <= reading.t + dedupWindow { continue }
            if let last = kept.last, reading.t - last.t <= dedupWindow { continue }
            kept.append(reading)
        }
        return kept
    }

    static func upload(request: Request, context: AppContext, db: PostgresClient) async throws -> StoredResponse {
        let accountId = try context.accountId
        let body = try await request.decode(as: ReadingsUpload.self, context: context)
        guard !body.readings.isEmpty else { return StoredResponse(stored: 0) }
        guard body.readings.allSatisfy({ $0.v.isFinite && $0.t >= 0 }) else {
            throw APIError.badRequest("readings need t >= 0 and a finite v")
        }
        let low = body.readings.map(\.t).min()! - dedupWindow
        let high = body.readings.map(\.t).max()! + dedupWindow

        return try await db.withTransaction(logger: context.logger) { connection in
            try await connection.query(
                "SELECT pg_advisory_xact_lock(\(readingsLock), \(Int32(truncatingIfNeeded: accountId)))",
                logger: context.logger
            )
            var stored: [Int64] = []
            for try await t in try await connection.query(
                "SELECT t FROM readings WHERE account_id = \(accountId) AND t BETWEEN \(low) AND \(high) ORDER BY t",
                logger: context.logger
            ).decode(Int64.self) {
                stored.append(t)
            }
            let kept = newReadings(body.readings, stored: stored)
            guard !kept.isEmpty else { return StoredResponse(stored: 0) }
            try await connection.query(
                """
                INSERT INTO readings (account_id, t, value, trend)
                SELECT \(accountId), t, v, trend
                FROM unnest(\(kept.map(\.t))::bigint[], \(kept.map(\.v))::float8[], \(kept.map(\.trend))::int2[]) AS r(t, v, trend)
                ON CONFLICT DO NOTHING
                """,
                logger: context.logger
            )
            return StoredResponse(stored: kept.count)
        }
    }

    static func list(request: Request, context: AppContext, db: PostgresClient) async throws -> ReadingsPage {
        let accountId = try context.accountId
        let page = try PageQuery(request)
        let lowerBound = max(page.from, (page.after ?? Int64.min) &+ 1)
        let rows = try await db.query(
            """
            SELECT t, value, trend FROM readings
            WHERE account_id = \(accountId) AND t >= \(lowerBound) AND t <= \(page.to)
            ORDER BY t
            LIMIT \(page.limit + 1)
            """,
            logger: context.logger
        )
        var readings: [Reading] = []
        for try await (t, value, trend) in rows.decode((Int64, Double, Int16).self) {
            readings.append(Reading(t: t, v: value, trend: trend))
        }
        let hasMore = readings.count > page.limit
        if hasMore { readings.removeLast() }
        return ReadingsPage(readings: readings, hasMore: hasMore)
    }
}
