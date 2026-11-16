import Foundation

public let sugarbarAppGroupIdentifier = "group.com.sugarbar"

public extension UserDefaults {
    /// UserDefaults is documented as thread-safe despite predating Sendable.
    /// The Mac app's group container is guarded by its code signature, which changes on every ad-hoc
    /// rebuild; macOS then serves an empty suite and rejects writes, so the Mac keeps its own domain.
    nonisolated(unsafe) static let sugarbarShared: UserDefaults = {
        #if os(macOS)
        return .standard
        #else
        return UserDefaults(suiteName: sugarbarAppGroupIdentifier) ?? .standard
        #endif
    }()
}
