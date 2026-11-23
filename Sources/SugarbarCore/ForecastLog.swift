import Foundation

/// Minutes after the latest Reading at which a logged Forecast keeps its prediction: every 5
/// minutes for the first hour, for the alerts, then 90 and 120.
public let forecastLogOffsets: [Int] = Array(stride(from: 5, through: 60, by: 5)) + [90, 120]
/// One logged Forecast per this much time; the rest are thinned away.
public let forecastLogSpacing: TimeInterval = 5 * 60 - 30
public let forecastLogRetention: TimeInterval = 90 * 86400

/// A logged Forecast's view of one Meal still absorbing.
public struct LoggedMeal: Codable, Equatable, Sendable {
    public let minutesAgo: Int
    public let carbsGrams: Double
    public let absorption: CarbAbsorption

    enum CodingKeys: String, CodingKey {
        case minutesAgo = "a", carbsGrams = "g", absorption = "c"
    }
}

/// A logged Forecast's view of one Bolus still acting.
public struct LoggedBolus: Codable, Equatable, Sendable {
    public let minutesAgo: Int
    public let units: Double

    enum CodingKeys: String, CodingKey {
        case minutesAgo = "a", units = "u"
    }
}

/// What one Forecast predicted and what it knew: kept compactly, one line per Forecast.
public struct ForecastLogEntry: Codable, Equatable, Sendable {
    /// The latest Reading's time, where the Forecast starts.
    public let date: Date
    public let glucose: Double
    /// The predicted value at each of `forecastLogOffsets`.
    public let predicted: [Double]
    public let insulinOnBoard: Double
    public let carbsOnBoard: Double
    /// mmol/L per minute.
    public let trendRate: Double?
    public let unexplainedRate: Double?
    public let carbFactor: Double
    public let meals: [LoggedMeal]
    public let boluses: [LoggedBolus]
    public let therapy: TherapySettings
    public let lowThreshold: Double

    public init(
        date: Date,
        glucose: Double,
        predicted: [Double],
        insulinOnBoard: Double,
        carbsOnBoard: Double,
        trendRate: Double?,
        unexplainedRate: Double?,
        carbFactor: Double,
        meals: [LoggedMeal],
        boluses: [LoggedBolus],
        therapy: TherapySettings,
        lowThreshold: Double
    ) {
        self.date = date
        self.glucose = glucose
        self.predicted = predicted
        self.insulinOnBoard = insulinOnBoard
        self.carbsOnBoard = carbsOnBoard
        self.trendRate = trendRate
        self.unexplainedRate = unexplainedRate
        self.carbFactor = carbFactor
        self.meals = meals
        self.boluses = boluses
        self.therapy = therapy
        self.lowThreshold = lowThreshold
    }

    public func predicted(atMinute minute: Int) -> Double? {
        forecastLogOffsets.firstIndex(of: minute).flatMap { $0 < predicted.count ? predicted[$0] : nil }
    }

    /// The lowest prediction up to `window` ahead, from the 5-minute points kept.
    public func lowestPredicted(within window: TimeInterval) -> Double? {
        zip(forecastLogOffsets, predicted).filter { Double($0.0 * 60) <= window }.map(\.1).min()
    }

    /// The CGM trend's unexplained part was steering the first half hour.
    public var trendBlendActive: Bool { abs(unexplainedRate ?? 0) > 0.005 }
    public var carbSlowdownActive: Bool { carbFactor != 1 }

    enum CodingKeys: String, CodingKey {
        case date = "t", glucose = "g", predicted = "p", insulinOnBoard = "iob", carbsOnBoard = "cob"
        case trendRate = "tr", unexplainedRate = "ur", carbFactor = "cf", meals = "m", boluses = "b"
        case therapy = "s", lowThreshold = "lo"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = Date(timeIntervalSince1970: try container.decode(TimeInterval.self, forKey: .date))
        glucose = try container.decode(Double.self, forKey: .glucose)
        predicted = try container.decode([Double].self, forKey: .predicted)
        insulinOnBoard = try container.decode(Double.self, forKey: .insulinOnBoard)
        carbsOnBoard = try container.decode(Double.self, forKey: .carbsOnBoard)
        trendRate = try container.decodeIfPresent(Double.self, forKey: .trendRate)
        unexplainedRate = try container.decodeIfPresent(Double.self, forKey: .unexplainedRate)
        carbFactor = try container.decode(Double.self, forKey: .carbFactor)
        meals = try container.decodeIfPresent([LoggedMeal].self, forKey: .meals) ?? []
        boluses = try container.decodeIfPresent([LoggedBolus].self, forKey: .boluses) ?? []
        therapy = try container.decode(LoggedTherapy.self, forKey: .therapy).settings
        lowThreshold = try container.decode(Double.self, forKey: .lowThreshold)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date.timeIntervalSince1970.rounded(), forKey: .date)
        try container.encode(rounded(glucose), forKey: .glucose)
        try container.encode(predicted.map(rounded), forKey: .predicted)
        try container.encode(rounded(insulinOnBoard), forKey: .insulinOnBoard)
        try container.encode(rounded(carbsOnBoard), forKey: .carbsOnBoard)
        try container.encodeIfPresent(trendRate.map { ($0 * 1000).rounded() / 1000 }, forKey: .trendRate)
        try container.encodeIfPresent(unexplainedRate.map { ($0 * 1000).rounded() / 1000 }, forKey: .unexplainedRate)
        try container.encode(rounded(carbFactor), forKey: .carbFactor)
        if !meals.isEmpty { try container.encode(meals, forKey: .meals) }
        if !boluses.isEmpty { try container.encode(boluses, forKey: .boluses) }
        try container.encode(LoggedTherapy(therapy), forKey: .therapy)
        try container.encode(lowThreshold, forKey: .lowThreshold)
    }

    private func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}

/// Therapy Settings under short keys, since every logged Forecast carries a copy.
private struct LoggedTherapy: Codable {
    let s: Double?
    let r: Double?
    let pk: Double
    let du: Double
    let af: Double
    let an: Double
    let asl: Double
    let tb: Double
    let cs: Double
    let cf: Double

    init(_ therapy: TherapySettings) {
        s = therapy.insulinSensitivity
        r = therapy.carbRatio
        pk = therapy.insulinPeak
        du = therapy.insulinDuration
        af = therapy.fastCarbAbsorptionTime
        an = therapy.carbAbsorptionTime
        asl = therapy.slowCarbAbsorptionTime
        tb = therapy.trendBlendDuration
        cs = therapy.slowestCarbFactor
        cf = therapy.fastestCarbFactor
    }

    var settings: TherapySettings {
        TherapySettings(
            insulinSensitivity: s, carbRatio: r, insulinDuration: du, insulinPeak: pk, carbAbsorptionTime: an,
            fastCarbAbsorptionTime: af, slowCarbAbsorptionTime: asl, trendBlendDuration: tb,
            slowestCarbFactor: cs, fastestCarbFactor: cf
        )
    }
}

public extension ForecastLogEntry {
    /// The log line for `forecast`, with the Meals and Boluses that were still acting at its start.
    init?(forecast: Forecast, doses: [InsulinDose], meals: [Meal], therapy: TherapySettings, thresholds: Thresholds) {
        guard let start = forecast.points.first else { return nil }
        let byOffset = Dictionary(forecast.points.map { (Int(($0.date.timeIntervalSince(start.date) / 60).rounded()), $0.value) }) { $1 }
        let predicted = forecastLogOffsets.compactMap { byOffset[$0] }
        guard predicted.count == forecastLogOffsets.count else { return nil }
        func minutesAgo(_ date: Date) -> Int { Int((start.date.timeIntervalSince(date) / 60).rounded()) }
        self.init(
            date: start.date,
            glucose: start.value,
            predicted: predicted,
            insulinOnBoard: forecast.insulinOnBoard,
            carbsOnBoard: forecast.carbsOnBoard,
            trendRate: forecast.trendRate,
            unexplainedRate: forecast.unexplainedRate,
            carbFactor: forecast.carbAbsorptionFactor,
            meals: meals
                .filter { $0.isEaten && $0.timestamp <= start.date && start.date.timeIntervalSince($0.timestamp) < $0.absorptionTime(therapy) + 3600 }
                .map { LoggedMeal(minutesAgo: minutesAgo($0.timestamp), carbsGrams: $0.carbsGrams, absorption: $0.carbAbsorption) },
            boluses: doses
                .filter { $0.kind == .bolus && $0.timestamp <= start.date && start.date.timeIntervalSince($0.timestamp) < therapy.insulinDuration }
                .map { LoggedBolus(minutesAgo: minutesAgo($0.timestamp), units: $0.units) },
            therapy: therapy,
            lowThreshold: thresholds.low
        )
    }
}

/// Each device's own record of the Forecasts it made. Never synced.
public protocol ForecastLogStore: AnyObject, Sendable {
    /// Keeps `entry` unless one was logged less than `forecastLogSpacing` before it; true when kept.
    @discardableResult func append(_ entry: ForecastLogEntry) -> Bool
    func entries(in interval: ClosedRange<Date>) -> [ForecastLogEntry]
    /// Drops entries older than `forecastLogRetention` before `now`.
    func prune(now: Date)
}

func shouldLog(_ entry: ForecastLogEntry, after last: ForecastLogEntry?) -> Bool {
    guard let last else { return true }
    return entry.date.timeIntervalSince(last.date) >= forecastLogSpacing
}

/// Append-only month files, like History.
public final class FileForecastLogStore: ForecastLogStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var months: [MonthKey: [ForecastLogEntry]] = [:]
    private var last: ForecastLogEntry?
    private var lastPrune: Date?

    public init(directory: URL = FileForecastLogStore.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        FileHistoryStore.defaultDirectory().deletingLastPathComponent().appending(path: "ForecastLog", directoryHint: .isDirectory)
    }

    @discardableResult
    public func append(_ entry: ForecastLogEntry) -> Bool {
        lock.withLock {
            let latest = last ?? storedKeys().last.flatMap { loaded($0).last }
            guard shouldLog(entry, after: latest),
                  let data = try? JSONEncoder().encode(entry)
            else { return false }
            let key = MonthKey(entry.date)
            months[key] = loaded(key) + [entry]
            last = entry
            let line = Data((String(decoding: data, as: UTF8.self) + "\n").utf8)
            let file = file(key)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
            return true
        }
    }

    public func entries(in interval: ClosedRange<Date>) -> [ForecastLogEntry] {
        lock.withLock {
            storedKeys()
                .filter { $0.interval.overlaps(interval) }
                .flatMap { loaded($0).filter { interval.contains($0.date) } }
        }
    }

    /// Whole months go once every entry in them is past retention; `entries(in:)` never reaches further back.
    public func prune(now: Date) {
        lock.withLock {
            if let lastPrune, now.timeIntervalSince(lastPrune) < 86400 { return }
            lastPrune = now
            let cutoff = now.addingTimeInterval(-forecastLogRetention)
            for key in storedKeys() where key.next.start <= cutoff {
                try? FileManager.default.removeItem(at: file(key))
                months[key] = nil
            }
        }
    }

    private func file(_ key: MonthKey) -> URL { directory.appending(path: "forecasts-\(key).jsonl") }

    private func storedKeys() -> [MonthKey] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let onDisk = names.compactMap { name -> MonthKey? in
            guard name.hasPrefix("forecasts-"), name.hasSuffix(".jsonl") else { return nil }
            return MonthKey(String(name.dropFirst("forecasts-".count).dropLast(".jsonl".count)))
        }
        return Set(onDisk).sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }

    private func loaded(_ key: MonthKey) -> [ForecastLogEntry] {
        if let cached = months[key] { return cached }
        let decoder = JSONDecoder()
        let data = (try? Data(contentsOf: file(key))) ?? Data()
        let entries = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(ForecastLogEntry.self, from: Data($0.utf8)) }
            .sorted { $0.date < $1.date }
        months[key] = entries
        return entries
    }
}

public final class InMemoryForecastLogStore: ForecastLogStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ForecastLogEntry] = []

    public init(_ entries: [ForecastLogEntry] = []) {
        stored = entries.sorted { $0.date < $1.date }
    }

    @discardableResult
    public func append(_ entry: ForecastLogEntry) -> Bool {
        lock.withLock {
            guard shouldLog(entry, after: stored.last) else { return false }
            stored.append(entry)
            return true
        }
    }

    public func entries(in interval: ClosedRange<Date>) -> [ForecastLogEntry] {
        lock.withLock { stored.filter { interval.contains($0.date) } }
    }

    public func prune(now: Date) {
        lock.withLock { stored.removeAll { $0.date < now.addingTimeInterval(-forecastLogRetention) } }
    }
}

/// Logs `forecast` with what History and the Meals held when it was made.
public func recordForecast(_ forecast: Forecast?, history: HistoryStore, meals: [Meal], settings: Settings, log: ForecastLogStore, now: Date) {
    guard let forecast, let start = forecast.points.first?.date else { return }
    let since = start.addingTimeInterval(-replayContext)
    guard let entry = ForecastLogEntry(
        forecast: forecast,
        doses: history.doses(in: since...start),
        meals: meals.filter { $0.timestamp >= since },
        therapy: settings.therapy,
        thresholds: settings.thresholds
    ) else { return }
    if log.append(entry) { log.prune(now: now) }
}
