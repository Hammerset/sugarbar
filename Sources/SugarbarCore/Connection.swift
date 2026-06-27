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

/// Resolves which connection to follow: a valid stored preference wins, otherwise the
/// first connection (which auto-selects when there is only one). `nil` only when empty.
public func selectedConnection(from connections: [Connection], preferredPatientId: String?) -> Connection? {
    if let preferredPatientId,
       let match = connections.first(where: { $0.patientId == preferredPatientId }) {
        return match
    }
    return connections.first
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
