import Foundation

/// Any JSON value, so a record's payload can travel inside the sync request untouched.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    /// Equal for equal content: keys sorted, and arrays sorted too, because Swift encodes a Set
    /// (and a dictionary with enum keys) in a different order in every process.
    var canonicalText: String {
        switch self {
        case .null: "null"
        case let .bool(value): value ? "true" : "false"
        case let .number(value): "\(value)"
        case let .string(value): "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        case let .array(values): "[" + values.map(\.canonicalText).sorted().joined(separator: ",") + "]"
        case let .object(fields): "{" + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]!.canonicalText)" }.joined(separator: ",") + "}"
        }
    }
}

/// Milliseconds since 1970: the wire's precision, so a stamp survives the round trip exactly.
public typealias SyncStamp = Int64

extension SyncStamp {
    init(date: Date) {
        self = SyncStamp((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    var date: Date { Date(timeIntervalSince1970: TimeInterval(self) / 1000) }
}

enum SyncTimestamp {
    static func format(_ stamp: SyncStamp) -> String {
        let seconds = (stamp - ((stamp % 1000) + 1000) % 1000) / 1000
        let millis = stamp - seconds * 1000
        let base = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601)
        return String(base.dropLast()) + String(format: ".%03dZ", millis)
    }

    static func parse(_ text: String) -> SyncStamp? {
        var base = text
        var millis: SyncStamp = 0
        if let dot = text.firstIndex(of: ".") {
            let rest = text[text.index(after: dot)...]
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            millis = SyncStamp(String((String(digits) + "000").prefix(3))) ?? 0
            base = String(text[..<dot]) + rest.dropFirst(digits.count)
        }
        guard let date = try? Date(base, strategy: .iso8601) else { return nil }
        return SyncStamp(date: date) + millis
    }
}

public struct SyncChange: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String
    public var updatedAt: SyncStamp
    public var deleted: Bool
    public var payload: JSONValue?
    public var seq: Int64?

    public init(kind: String, id: String, updatedAt: SyncStamp, deleted: Bool, payload: JSONValue?, seq: Int64? = nil) {
        self.kind = kind
        self.id = id
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.payload = payload
        self.seq = seq
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, updatedAt, deleted, payload, seq
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        let text = try container.decode(String.self, forKey: .updatedAt)
        guard let stamp = SyncTimestamp.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: .updatedAt, in: container, debugDescription: "Not ISO 8601: \(text)")
        }
        updatedAt = stamp
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload)
        seq = try container.decodeIfPresent(Int64.self, forKey: .seq)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(SyncTimestamp.format(updatedAt), forKey: .updatedAt)
        try container.encode(deleted, forKey: .deleted)
        try container.encode(deleted ? .object([:]) : payload ?? .object([:]), forKey: .payload)
        try container.encodeIfPresent(seq, forKey: .seq)
    }
}

public struct SyncRequest: Codable, Equatable, Sendable {
    public var deviceId: String
    public var cursor: Int64
    public var changes: [SyncChange]

    public init(deviceId: String, cursor: Int64, changes: [SyncChange]) {
        self.deviceId = deviceId
        self.cursor = cursor
        self.changes = changes
    }
}

public struct SyncResponse: Codable, Equatable, Sendable {
    public var cursor: Int64
    public var hasMore: Bool
    public var changes: [SyncChange]

    public init(cursor: Int64, hasMore: Bool, changes: [SyncChange]) {
        self.cursor = cursor
        self.hasMore = hasMore
        self.changes = changes
    }
}

public struct WireReading: Codable, Equatable, Sendable {
    public var t: Int
    public var v: Double
    public var trend: Int?

    public init(t: Int, v: Double, trend: Int?) {
        self.t = t
        self.v = v
        self.trend = trend
    }

    init(_ reading: Reading) {
        self.init(t: Int(reading.timestamp.timeIntervalSince1970.rounded()), v: reading.value, trend: reading.trend.apiValue)
    }

    var reading: Reading {
        Reading(value: v, timestamp: Date(timeIntervalSince1970: TimeInterval(t)), trend: Trend(apiValue: trend ?? 0))
    }
}

/// The Dose JSON carries neither its id nor an epoch, so each one travels wrapped.
/// A deleted Dose travels as a tombstone with an empty payload, which apps that predate it skip.
public struct WireDose: Codable, Equatable, Sendable {
    public var id: String
    public var t: Int
    public var payload: JSONValue
    public var deleted: Bool?

    public init(id: String, t: Int, payload: JSONValue, deleted: Bool? = nil) {
        self.id = id
        self.t = t
        self.payload = payload
        self.deleted = deleted == true ? true : nil
    }

    init(_ dose: InsulinDose) throws {
        self.init(id: dose.id, t: Self.seconds(dose.timestamp), payload: try JSONValue(encoding: dose))
    }

    init(deleted deletion: DoseDeletion) {
        self.init(id: deletion.id, t: Self.seconds(deletion.timestamp), payload: .object([:]), deleted: true)
    }

    var isDeleted: Bool { deleted == true }

    private static func seconds(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }
}

public struct ReadingsBody: Codable, Equatable, Sendable {
    public var readings: [WireReading]
    public var hasMore: Bool?
}

public struct DosesBody: Codable, Equatable, Sendable {
    public var doses: [WireDose]
    public var hasMore: Bool?
}
