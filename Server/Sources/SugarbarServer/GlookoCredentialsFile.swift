import Foundation

/// The Glooko login per Sugarbar account, in a JSON file readable only by the server's user.
/// Kept out of Postgres so database dumps and backups never carry it.
public struct GlookoCredentialsFile: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    private struct Contents: Codable {
        var accounts: [String: GlookoCredentials] = [:]
    }

    public func load() throws -> [String: GlookoCredentials] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        do {
            return try JSONDecoder().decode(Contents.self, from: Data(contentsOf: URL(fileURLWithPath: path))).accounts
        } catch {
            throw ConfigurationError.invalid("cannot read the Glooko credentials file at \(path)")
        }
    }

    public func set(account: String, credentials: GlookoCredentials?) throws {
        var contents = Contents(accounts: try load())
        contents.accounts[account] = credentials
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: try JSONEncoder().encode(contents),
            attributes: [.posixPermissions: 0o600]
        ) else { throw ConfigurationError.invalid("cannot write \(path)") }
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
