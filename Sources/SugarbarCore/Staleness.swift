import Foundation

public let stalenessThreshold: TimeInterval = 300

public extension Reading {
    func age(at now: Date) -> TimeInterval {
        now.timeIntervalSince(timestamp)
    }

    func isStale(at now: Date, threshold: TimeInterval = stalenessThreshold) -> Bool {
        age(at: now) > threshold
    }
}
