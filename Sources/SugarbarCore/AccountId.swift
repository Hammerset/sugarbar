import CryptoKit
import Foundation

public func accountIdHeader(forUserId userId: String) -> String {
    SHA256.hash(data: Data(userId.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
