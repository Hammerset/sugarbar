import Foundation

public struct GraphSnapshot: Equatable, Sendable {
    public let latest: Reading
    public let history: [Reading]

    public init(latest: Reading, history: [Reading]) {
        self.latest = latest
        self.history = history
    }
}

private struct GraphEnvelope: Decodable {
    let data: GraphData

    struct GraphData: Decodable {
        let connection: ConnectionData
        let graphData: [Measurement]
    }

    struct ConnectionData: Decodable {
        let glucoseMeasurement: Measurement
    }

    struct Measurement: Decodable {
        let factoryTimestamp: String?
        let timestamp: String?
        let valueInMgPerDl: Double
        let trendArrow: Int?

        enum CodingKeys: String, CodingKey {
            case factoryTimestamp = "FactoryTimestamp"
            case timestamp = "Timestamp"
            case valueInMgPerDl = "ValueInMgPerDl"
            case trendArrow = "TrendArrow"
        }

        func reading() -> Reading? {
            guard let timestamp = parseLibreTimestamp(factoryTimestamp ?? timestamp) else { return nil }
            return Reading(
                value: mmolPerL(fromMgPerDl: valueInMgPerDl),
                timestamp: timestamp,
                trend: Trend(apiValue: trendArrow ?? 0)
            )
        }
    }
}

public func decodeGraph(_ data: Data) throws -> GraphSnapshot {
    let envelope = try JSONDecoder().decode(GraphEnvelope.self, from: data)
    guard let latest = envelope.data.connection.glucoseMeasurement.reading() else {
        throw LibreLinkUpError.unexpectedResponse
    }
    let history = envelope.data.graphData.compactMap { $0.reading() }
    return GraphSnapshot(latest: latest, history: history)
}

public func decodeLatestReading(_ data: Data) throws -> Reading {
    try decodeGraph(data).latest
}

private let libreTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "M/d/yyyy h:mm:ss a"
    return formatter
}()

func parseLibreTimestamp(_ string: String?) -> Date? {
    guard let string else { return nil }
    return libreTimestampFormatter.date(from: string)
}
