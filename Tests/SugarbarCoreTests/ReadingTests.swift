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

    @Test(arguments: [
        (Trend.fallingQuickly, "arrow.down"),
        (Trend.falling, "arrow.down.right"),
        (Trend.stable, "arrow.right"),
        (Trend.rising, "arrow.up.right"),
        (Trend.risingQuickly, "arrow.up"),
    ])
    func mapsTrendToArrowSymbol(trend: Trend, expected: String) {
        #expect(trend.symbolName == expected)
    }

    @Test func hasNoArrowWhenTrendNotDetermined() {
        #expect(Trend.notDetermined.symbolName == nil)
        #expect(Trend.notDetermined.arrowText == nil)
    }

    @Test(arguments: [
        (Trend.fallingQuickly, "↓"),
        (Trend.falling, "↘"),
        (Trend.stable, "→"),
        (Trend.rising, "↗"),
        (Trend.risingQuickly, "↑"),
    ])
    func mapsTrendToArrowText(trend: Trend, expected: String) {
        #expect(trend.arrowText == expected)
    }

    @Test(arguments: [
        (5.3, "5.3"),
        (7.0, "7.0"),
        (5.34, "5.3"),
        (5.36, "5.4"),
        (12.0, "12.0"),
    ])
    func formatsToOneDecimal(value: Double, expected: String) {
        #expect(formatMmolPerL(value) == expected)
    }
}

private extension Double {
    func isApprox(_ other: Double, tolerance: Double = 0.01) -> Bool {
        abs(self - other) < tolerance
    }
}
