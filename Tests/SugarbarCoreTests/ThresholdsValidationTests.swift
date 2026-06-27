import Testing

@testable import SugarbarCore

@Suite struct ThresholdsValidationTests {
    @Test func standardIsValid() {
        #expect(Thresholds.standard.isValid)
    }

    @Test func acceptsStrictlyIncreasing() {
        let custom = Thresholds(urgentLow: 4.0, low: 4.5, high: 8.0, urgentHigh: 12.0)
        #expect(custom.isValid)
        #expect(Thresholds.validated(urgentLow: 4.0, low: 4.5, high: 8.0, urgentHigh: 12.0) == custom)
    }

    @Test func rejectsOutOfOrder() {
        #expect(Thresholds.validated(urgentLow: 3.0, low: 3.9, high: 13.9, urgentHigh: 10.0) == nil)
        #expect(Thresholds.validated(urgentLow: 3.9, low: 3.0, high: 10.0, urgentHigh: 13.9) == nil)
    }

    @Test func rejectsEqualNeighbours() {
        #expect(Thresholds.validated(urgentLow: 3.0, low: 3.0, high: 10.0, urgentHigh: 13.9) == nil)
        #expect(Thresholds.validated(urgentLow: 3.0, low: 3.9, high: 10.0, urgentHigh: 10.0) == nil)
    }
}
