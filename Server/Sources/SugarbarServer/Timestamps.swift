import Foundation

enum Timestamps {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    static func parse(_ string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? wholeSeconds.parse(string))
    }

    /// Formats from whole milliseconds: the stored microseconds come back as a Double that a
    /// formatter would sometimes truncate to the millisecond below.
    static func format(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = milliseconds.floorDivided(by: 1000)
        let fraction = milliseconds - seconds * 1000
        let whole = wholeSeconds.format(Date(timeIntervalSince1970: TimeInterval(seconds)))
        return whole.dropLast() + String(format: ".%03dZ", fraction)
    }
}

private extension Int64 {
    func floorDivided(by divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return (self % divisor < 0) ? quotient - 1 : quotient
    }
}
