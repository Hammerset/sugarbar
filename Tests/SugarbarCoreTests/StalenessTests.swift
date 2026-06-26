import Foundation
import Testing

@testable import SugarbarCore

@Suite struct StalenessTests {
    private func reading(at timestamp: Date) -> Reading {
        Reading(value: 5.5, timestamp: timestamp, trend: .stable)
    }

    @Test func ageIsSecondsSinceTimestamp() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let r = reading(at: now.addingTimeInterval(-90))
        #expect(r.age(at: now) == 90)
    }

    @Test func freshReadingIsNotStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(reading(at: now.addingTimeInterval(-60)).isStale(at: now) == false)
    }

    @Test func readingOlderThanFiveMinutesIsStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(reading(at: now.addingTimeInterval(-301)).isStale(at: now))
    }

    @Test func exactlyFiveMinutesIsNotYetStale() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(reading(at: now.addingTimeInterval(-300)).isStale(at: now) == false)
    }
}
