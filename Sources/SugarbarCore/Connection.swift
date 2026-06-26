import Foundation

public struct Connection: Equatable, Sendable {
    public let patientId: String
    public let firstName: String
    public let lastName: String

    public init(patientId: String, firstName: String, lastName: String) {
        self.patientId = patientId
        self.firstName = firstName
        self.lastName = lastName
    }
}

private struct ConnectionsEnvelope: Decodable {
    let data: [ConnectionData]

    struct ConnectionData: Decodable {
        let patientId: String
        let firstName: String?
        let lastName: String?
    }
}

public func decodeConnections(_ data: Data) throws -> [Connection] {
    let envelope = try JSONDecoder().decode(ConnectionsEnvelope.self, from: data)
    return envelope.data.map {
        Connection(
            patientId: $0.patientId,
            firstName: $0.firstName ?? "",
            lastName: $0.lastName ?? ""
        )
    }
}
