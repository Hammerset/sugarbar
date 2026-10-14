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

private struct GraphDataEnvelope: Decodable {
    let series: Series?

    struct Series: Decodable {
        let gkInsulinBolus: [Entry]?
        let gkInsulinBasal: [Entry]?
    }

    struct Entry: Decodable {
        let name: String?
        let timestamp: String?
        let value: Double?
        let deviceName: String?

        func dose(kind: InsulinKind, timeZone: TimeZone) -> InsulinDose? {
            guard let units = value, let timestamp = parseGlookoTimestamp(timestamp, timeZone: timeZone) else { return nil }
            return InsulinDose(kind: kind, units: units, timestamp: timestamp, insulinName: name, deviceName: deviceName)
        }
    }
}

public func decodeGlookoDoses(_ data: Data, timeZone: TimeZone = .current) throws -> [InsulinDose] {
    let envelope = try JSONDecoder().decode(GraphDataEnvelope.self, from: data)
    let boluses = (envelope.series?.gkInsulinBolus ?? []).compactMap { $0.dose(kind: .bolus, timeZone: timeZone) }
    let basals = (envelope.series?.gkInsulinBasal ?? []).compactMap { $0.dose(kind: .basal, timeZone: timeZone) }
    return (boluses + basals).sorted { $0.timestamp < $1.timestamp }
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
