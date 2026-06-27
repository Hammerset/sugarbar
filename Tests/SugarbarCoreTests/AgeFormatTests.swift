import Foundation
import Testing

@testable import SugarbarCore

@Suite struct AgeFormatTests {
    @Test func justNowUnderAFewSeconds() {
        #expect(formatAge(0) == "just now")
        #expect(formatAge(4) == "just now")
    }

    @Test func secondsUnderAMinute() {
        #expect(formatAge(5) == "5s ago")
        #expect(formatAge(42) == "42s ago")
        #expect(formatAge(59) == "59s ago")
    }

    @Test func sixtySecondsRollsToMinutes() {
        #expect(formatAge(60) == "1 min ago")
    }

    @Test func justUnderAnHourStaysInMinutes() {
        #expect(formatAge(3599) == "59 min ago")
    }

    @Test func oneHourRollsToHours() {
        #expect(formatAge(3600) == "1 h ago")
    }

    @Test func justUnderADayStaysInHours() {
        #expect(formatAge(24 * 3600 - 1) == "23 h ago")
    }

    @Test func oneDayRollsToDays() {
        #expect(formatAge(24 * 3600) == "1 d ago")
    }

    @Test func sevenDaysRollsToWeeks() {
        #expect(formatAge(6 * 86400) == "6 d ago")
        #expect(formatAge(7 * 86400) == "1 w ago")
    }
}
