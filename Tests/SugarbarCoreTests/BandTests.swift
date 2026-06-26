import Testing

@testable import SugarbarCore

@Suite struct BandTests {
    @Test(arguments: [
        (2.5, Band.urgentLow),
        (3.5, Band.low),
        (5.3, Band.inRange),
        (11.0, Band.high),
        (16.0, Band.urgentHigh),
    ])
    func classifiesInteriorValues(value: Double, expected: Band) {
        #expect(Band(mmolPerL: value) == expected)
    }

    @Test(arguments: [
        (2.99, Band.urgentLow),
        (3.0, Band.low),
        (3.89, Band.low),
        (3.9, Band.inRange),
        (10.0, Band.inRange),
        (10.01, Band.high),
        (13.9, Band.high),
        (13.91, Band.urgentHigh),
    ])
    func classifiesBoundaries(value: Double, expected: Band) {
        #expect(Band(mmolPerL: value) == expected)
    }

    @Test func honoursCustomThresholds() {
        let tighter = Thresholds(urgentLow: 4.0, low: 4.5, high: 8.0, urgentHigh: 12.0)
        #expect(Band(mmolPerL: 4.2, thresholds: tighter) == .low)
        #expect(Band(mmolPerL: 9.0, thresholds: tighter) == .high)
        #expect(Band(mmolPerL: 6.0, thresholds: tighter) == .inRange)
    }
}
