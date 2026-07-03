import Foundation

public let sugarbarAppGroupIdentifier = "group.com.sugarbar"

public extension UserDefaults {
    /// UserDefaults is documented as thread-safe despite predating Sendable.
    nonisolated(unsafe) static let sugarbarShared = UserDefaults(suiteName: sugarbarAppGroupIdentifier) ?? .standard
}
