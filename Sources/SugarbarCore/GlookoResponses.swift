import Foundation

public struct GlookoDashboard: Equatable, Sendable {
    public let patientId: String
    public let apiBase: URL
}

func parseCSRFToken(fromLoginPage html: String) -> String? {
    firstCapture(#"name="csrf-token" content="([^"]+)""#, in: html)
}

/// The dashboard's inline bootstrap script carries the patient id and the regional
/// API host; both are absent when sign-in bounced back to the login form.
func parseDashboard(_ html: String) -> GlookoDashboard? {
    guard
        let patientId = firstCapture(#"window\.patient\s*=\s*"([^"]+)""#, in: html),
        let apiString = firstCapture(#"apiUrl:\s*'([^']+)'"#, in: html),
        let apiBase = URL(string: apiString)
    else { return nil }
    return GlookoDashboard(patientId: patientId, apiBase: apiBase)
}

private func firstCapture(_ pattern: String, in text: String) -> String? {
    guard
        let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}

public let glookoCGMSeries = ["cgmLow", "cgmNormal", "cgmHigh"]
public let glookoInsulinSeries = ["gkInsulinBolus", "gkInsulinBasal"]

public struct GlookoHistory: Equatable, Sendable {
    public let readings: [Reading]
    public let doses: [InsulinDose]
}

private struct GraphDataEnvelope: Decodable {
    let series: Series?

    struct Series: Decodable {
        let gkInsulinBolus: [Entry]?
        let gkInsulinBasal: [Entry]?
        let cgmLow: [Entry]?
        let cgmNormal: [Entry]?
        let cgmHigh: [Entry]?
    }

    struct Entry: Decodable {
        let name: String?
        let timestamp: String?
        let value: Double?
        let deviceName: String?
        let calculated: Bool?

        func dose(kind: InsulinKind, timeZone: TimeZone) -> InsulinDose? {
            guard let units = value, let timestamp = parseGlookoTimestamp(timestamp, timeZone: timeZone) else { return nil }
            return InsulinDose(kind: kind, units: units, timestamp: timestamp, insulinName: name, deviceName: deviceName)
        }

        /// Glooko has no Trend for CGM points, and skips its own interpolated ("calculated") ones.
        func reading(timeZone: TimeZone) -> Reading? {
            guard calculated != true, let value, let timestamp = parseGlookoTimestamp(timestamp, timeZone: timeZone)
            else { return nil }
            return Reading(value: mmolPerL(fromMgPerDl: glookoMgPerDl(value)), timestamp: timestamp, trend: .notDetermined)
        }
    }
}

/// CGM values are mg/dL x 100, with sentinels for the sensor's LO and HI clamps.
func glookoMgPerDl(_ value: Double) -> Double {
    switch value {
    case 200_100: 500
    case 100: 40
    default: value / 100
    }
}

public func decodeGlookoHistory(_ data: Data, timeZone: TimeZone = .current) throws -> GlookoHistory {
    let series = try JSONDecoder().decode(GraphDataEnvelope.self, from: data).series
    let boluses = (series?.gkInsulinBolus ?? []).compactMap { $0.dose(kind: .bolus, timeZone: timeZone) }
    let basals = (series?.gkInsulinBasal ?? []).compactMap { $0.dose(kind: .basal, timeZone: timeZone) }
    let cgm = (series?.cgmLow ?? []) + (series?.cgmNormal ?? []) + (series?.cgmHigh ?? [])
    return GlookoHistory(
        readings: cgm.compactMap { $0.reading(timeZone: timeZone) }.sorted { $0.timestamp < $1.timestamp },
        doses: (boluses + basals).sorted { $0.timestamp < $1.timestamp }
    )
}

private let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

/// Glooko's timestamps (and query dates) are the patient's wall-clock time with a
/// literal "Z" suffix, not UTC: "22:20:49.000Z" means 22:20 local.
func parseGlookoTimestamp(_ string: String?, timeZone: TimeZone) -> Date? {
    guard let string,
          let wallClock = (try? fractionalISO8601.parse(string)) ?? (try? Date.ISO8601FormatStyle().parse(string))
    else { return nil }
    return wallClock.addingTimeInterval(-Double(timeZone.secondsFromGMT(for: wallClock)))
}

func formatGlookoTimestamp(_ date: Date, timeZone: TimeZone) -> String {
    fractionalISO8601.format(date.addingTimeInterval(Double(timeZone.secondsFromGMT(for: date))))
}
