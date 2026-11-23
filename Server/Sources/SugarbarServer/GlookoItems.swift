import Crypto
import Foundation

/// The Glooko entry one Sugarbar record should be, without the per-write stamps.
struct GlookoItem: Equatable {
    var fields: [String: JSONValue]
    /// When the meal was eaten or the dose taken.
    var eventAt: Date

    var fingerprint: String { GlookoItems.fingerprint(fields) }

    var isDeleted: Bool { fields["softDeleted"] == .bool(true) }

    func deleted() -> GlookoItem {
        var copy = self
        copy.fields["softDeleted"] = .bool(true)
        return copy
    }
}

enum GlookoItems {
    static let mealKind = "meal"
    static let manualDoseKind = "manualDose"

    static func collection(for sourceKind: String) -> String {
        sourceKind == mealKind ? "foods" : "insulins"
    }

    /// Derived from the Sugarbar id, so a retry after a crash writes the same Glooko entry again.
    static func guid(for sourceKind: String, id: String, purpose: String = "entry") -> String {
        var bytes = Array(SHA256.hash(data: Data("sugarbar/\(purpose)/\(sourceKind)/\(id)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }

    static func fingerprint(_ fields: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(JSONValue.object(fields))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What goes on the wire: the item plus Glooko's required write stamps.
    static func wire(_ item: GlookoItem, now: Date) -> JSONValue {
        var fields = item.fields
        fields["updatedAt"] = .string(Timestamps.format(now))
        fields["syncTimestamp"] = .string(Timestamps.format(now))
        return .object(fields)
    }

    /// Nil when the record should not be in Glooko: deleted, planned, or not a manual Dose.
    static func item(sourceKind: String, payload: JSONValue?, guid: String, mealGuid: String?, wallClock: GlookoWallClock) -> GlookoItem? {
        guard let payload else { return nil }
        switch sourceKind {
        case mealKind: return food(meal: payload, guid: guid, mealGuid: mealGuid, wallClock: wallClock)
        case manualDoseKind: return insulin(dose: payload, guid: guid, wallClock: wallClock)
        default: return nil
        }
    }

    /// Swift's default `Date` coding: seconds since 2001-01-01, as the apps send it.
    struct MealPayload: Codable {
        var id: String
        var timestamp: Double
        var carbsGrams: Double
        var summary: String?
        var state: String?
        var carbAbsorption: String?
    }

    struct DosePayload: Decodable {
        let kind: String
        let units: Double
        let timestamp: Double
        let insulinName: String?
        let origin: String?
    }

    private static func food(meal payload: JSONValue, guid: String, mealGuid: String?, wallClock: GlookoWallClock) -> GlookoItem? {
        guard let meal = try? payload.decode(MealPayload.self), (meal.state ?? "eaten") == "eaten" else { return nil }
        let eatenAt = Date(timeIntervalSinceReferenceDate: meal.timestamp)
        let summary = (meal.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return GlookoItem(fields: [
            "guid": .string(guid),
            "mealGuid": .string(mealGuid ?? Self.guid(for: mealKind, id: meal.id, purpose: "meal")),
            "timestamp": .string(wallClock.format(eatenAt)),
            "name": .string(summary.isEmpty ? "Meal" : summary),
            "carbs": .double(meal.carbsGrams),
            "fat": .null,
            "protein": .null,
            "calories": .null,
            "manuallyEnteredText": .bool(true),
            "numberOfServings": .int(0),
            "servingQuantity": .double(0),
            "servingUnit": .null,
            "source": .string("QuickAdd"),
            "softDeleted": .bool(false),
        ], eventAt: eatenAt)
    }

    private static func insulin(dose payload: JSONValue, guid: String, wallClock: GlookoWallClock) -> GlookoItem? {
        guard let dose = try? payload.decode(DosePayload.self), dose.origin == "manual",
              dose.kind == "bolus" || dose.kind == "basal", dose.units > 0
        else { return nil }
        let takenAt = Date(timeIntervalSinceReferenceDate: dose.timestamp)
        let name = (dose.insulinName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return GlookoItem(fields: [
            "guid": .string(guid),
            "timestamp": .string(wallClock.format(takenAt)),
            "name": .string(name.isEmpty ? "Insulin" : name),
            "value": .double(dose.units),
            "units": .string("units"),
            "type": .string("Insulin"),
            "insulinType": .string(dose.kind),
            "deviceDelivered": .bool(false),
            "manuallyEnteredText": .bool(true),
            "editable": .bool(true),
            "incomplete": .bool(false),
            "meterGuid": .null,
            "cgmDeviceGuid": .null,
            "pumpGuid": .null,
            "insulinPenGuid": .null,
            "medicationGuid": .null,
            "softDeleted": .bool(false),
        ], eventAt: takenAt)
    }

    /// A carbs entry made in the Glooko app, as a Sugarbar Meal with its own id.
    static func mealPayload(id: UUID, food: GlookoFood, wallClock: GlookoWallClock) -> JSONValue? {
        guard let carbs = food.carbs, carbs > 0, let timestamp = food.timestamp, let eatenAt = wallClock.parse(timestamp) else { return nil }
        return try? JSONValue(encoding: MealPayload(
            id: id.uuidString,
            timestamp: eatenAt.timeIntervalSinceReferenceDate,
            carbsGrams: carbs,
            summary: food.name ?? "",
            state: "eaten",
            carbAbsorption: "normal"
        ))
    }

    /// What of a Glooko food Sugarbar reflects, to notice edits made in the Glooko app.
    static func remoteFingerprint(_ food: GlookoFood) -> String {
        fingerprint([
            "timestamp": food.timestamp.map(JSONValue.string) ?? .null,
            "name": food.name.map(JSONValue.string) ?? .null,
            "carbs": food.carbs.map(JSONValue.double) ?? .null,
            "softDeleted": .bool(food.softDeleted ?? false),
        ])
    }
}

extension JSONValue {
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
