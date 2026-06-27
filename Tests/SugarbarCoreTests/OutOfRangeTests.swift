import Foundation
import Testing

@testable import SugarbarCore

@Suite struct OutOfRangeTests {
    private func reading(mgPerDl: Double) -> Reading {
        Reading(value: mmolPerL(fromMgPerDl: mgPerDl), timestamp: Date(), trend: .stable)
    }

    @Test func valueAtOrBelowSensorFloorIsLow() {
        #expect(reading(mgPerDl: 40).outOfRange == .low)
        #expect(reading(mgPerDl: 30).outOfRange == .low)
    }

    @Test func valueAtOrAboveSensorCeilingIsHigh() {
        #expect(reading(mgPerDl: 500).outOfRange == .high)
        #expect(reading(mgPerDl: 600).outOfRange == .high)
    }

    @Test func valueInsideMeasurableRangeIsNotOutOfRange() {
        #expect(reading(mgPerDl: 41).outOfRange == nil)
        #expect(reading(mgPerDl: 100).outOfRange == nil)
        #expect(reading(mgPerDl: 499).outOfRange == nil)
    }

    @Test func labelsAreLoAndHi() {
        #expect(OutOfRange.low.label == "LO")
        #expect(OutOfRange.high.label == "HI")
    }
}
