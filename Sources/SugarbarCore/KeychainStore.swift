import Foundation
import Security

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}

public final class KeychainStore: CredentialStore, @unchecked Sendable {
    private let credentialsService: String
    private let tokenService: String

    public init(servicePrefix: String = "no.ignite.sugarbar") {
        credentialsService = "\(servicePrefix).credentials"
        tokenService = "\(servicePrefix).token"
    }

    public func loadCredentials() throws -> Credentials? {
        guard let item = try read(service: credentialsService, wantsAccount: true),
              let email = item.account
        else { return nil }
        return Credentials(email: email, password: String(decoding: item.data, as: UTF8.self))
    }

    public func saveCredentials(_ credentials: Credentials) throws {
        try write(
            service: credentialsService,
            account: credentials.email,
            data: Data(credentials.password.utf8)
        )
    }

    public func clearCredentials() throws {
        try delete(service: credentialsService)
    }

    public func loadToken() throws -> String? {
        guard let item = try read(service: tokenService, wantsAccount: false) else { return nil }
        return String(decoding: item.data, as: UTF8.self)
    }

    public func saveToken(_ token: String) throws {
        try write(service: tokenService, account: "token", data: Data(token.utf8))
    }

    public func clearToken() throws {
        try delete(service: tokenService)
    }

    private func read(service: String, wantsAccount: Bool) throws -> (account: String?, data: Data)? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if wantsAccount {
            query[kSecReturnAttributes as String] = true
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }

        if wantsAccount {
            guard let dict = result as? [String: Any],
                  let data = dict[kSecValueData as String] as? Data
            else { throw KeychainError(status: errSecInternalError) }
            return (dict[kSecAttrAccount as String] as? String, data)
        }

        guard let data = result as? Data else { throw KeychainError(status: errSecInternalError) }
        return (nil, data)
    }

    private func write(service: String, account: String, data: Data) throws {
        try delete(service: service)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func delete(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
