import Foundation

private struct GraphEnvelope: Decodable {
    let data: GraphData

    struct GraphData: Decodable {
        let connection: ConnectionData
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
    }
}

public func decodeLatestReading(_ data: Data) throws -> Reading {
    let envelope = try JSONDecoder().decode(GraphEnvelope.self, from: data)
    let measurement = envelope.data.connection.glucoseMeasurement

    guard let timestamp = parseLibreTimestamp(measurement.factoryTimestamp ?? measurement.timestamp) else {
        throw LibreLinkUpError.unexpectedResponse
    }

    return Reading(
        value: mmolPerL(fromMgPerDl: measurement.valueInMgPerDl),
        timestamp: timestamp,
        trend: Trend(apiValue: measurement.trendArrow ?? 0)
    )
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
