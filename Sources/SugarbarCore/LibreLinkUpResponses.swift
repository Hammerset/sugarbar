import Foundation

public enum LoginResult: Equatable, Sendable {
    case redirect(region: String)
    case success(token: String, userId: String)
}

private struct LoginEnvelope: Decodable {
    let status: Int
    let data: LoginData?

    struct LoginData: Decodable {
        let redirect: Bool?
        let region: String?
        let authTicket: AuthTicket?
        let user: User?
    }

    struct AuthTicket: Decodable {
        let token: String
    }

    struct User: Decodable {
        let id: String
    }
}

public func decodeLogin(_ data: Data) throws -> LoginResult {
    let envelope = try JSONDecoder().decode(LoginEnvelope.self, from: data)

    switch envelope.status {
    case 0:
        break
    case 4:
        throw LibreLinkUpError.termsNotAccepted
    default:
        throw LibreLinkUpError.authenticationFailed
    }

    if let payload = envelope.data, payload.redirect == true, let region = payload.region {
        return .redirect(region: region)
    }

    if let ticket = envelope.data?.authTicket, let user = envelope.data?.user {
        return .success(token: ticket.token, userId: user.id)
    }

    throw LibreLinkUpError.unexpectedResponse
}
