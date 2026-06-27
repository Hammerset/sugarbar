import Foundation

public struct GraphSnapshot: Equatable, Sendable {
    public let latest: Reading?
    public let history: [Reading]
    public let sensorActivation: Date?

    public init(latest: Reading?, history: [Reading], sensorActivation: Date? = nil) {
        self.latest = latest
        self.history = history
        self.sensorActivation = sensorActivation
    }
}

private struct GraphEnvelope: Decodable {
    let status: Int?
    let data: GraphData?

    struct GraphData: Decodable {
        let connection: ConnectionData?
        let graphData: [Measurement]?
    }

    struct ConnectionData: Decodable {
        let glucoseMeasurement: Measurement?
        let sensor: Sensor?
    }

    struct Sensor: Decodable {
        let a: Double?
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
    if envelope.status == 4 { throw LibreLinkUpError.termsNotAccepted }
    let connection = envelope.data?.connection
    let latest = connection?.glucoseMeasurement?.reading()
    let history = (envelope.data?.graphData ?? []).compactMap { $0.reading() }
    let activation = connection?.sensor?.a.map { Date(timeIntervalSince1970: $0) }
    return GraphSnapshot(latest: latest, history: history, sensorActivation: activation)
}

public func decodeLatestReading(_ data: Data) throws -> Reading {
    guard let latest = try decodeGraph(data).latest else {
        throw LibreLinkUpError.unexpectedResponse
    }
    return latest
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
