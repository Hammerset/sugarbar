import Foundation
import Testing

@testable import SugarbarCore

@Suite struct ReadingTests {
    @Test func convertsMgPerDlToMmolPerL() {
        #expect(mmolPerL(fromMgPerDl: 100).isApprox(5.55))
        #expect(mmolPerL(fromMgPerDl: 0) == 0)
        #expect(mmolPerL(fromMgPerDl: 180).isApprox(9.99))
    }

    @Test(arguments: [
        (1, Trend.fallingQuickly),
        (2, Trend.falling),
        (3, Trend.stable),
        (4, Trend.rising),
        (5, Trend.risingQuickly),
        (0, Trend.notDetermined),
        (99, Trend.notDetermined),
        (-1, Trend.notDetermined),
    ])
    func mapsApiTrendValue(apiValue: Int, expected: Trend) {
        #expect(Trend(apiValue: apiValue) == expected)
    }
}

private extension Double {
    func isApprox(_ other: Double, tolerance: Double = 0.01) -> Bool {
        abs(self - other) < tolerance
    }
}
