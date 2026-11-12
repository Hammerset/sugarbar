import Foundation

/// Never pruned. Readings are de-duplicated by time; Doses by `id`, the latest copy winning.
/// `doses(in:)` is already reconciled: a manual Dose superseded by its Glooko Dose is left out.
public protocol HistoryStore: AnyObject, Sendable {
    func readings(in interval: ClosedRange<Date>) -> [Reading]
    func doses(in interval: ClosedRange<Date>) -> [InsulinDose]
    @discardableResult func append(readings: [Reading]) -> Int
    @discardableResult func append(doses: [InsulinDose]) -> Int
    func delete(dose: InsulinDose)
    func glookoCursor() -> Date?
    func setGlookoCursor(_ date: Date)
}

public extension HistoryStore {
    /// Delete-then-append, so an edit that moves a Dose into another month leaves no copy behind.
    func replace(_ old: InsulinDose, with new: InsulinDose) {
        delete(dose: old)
        append(doses: [new])
    }

    func recentManualDoses(now: Date, lookback: TimeInterval = 48 * 3600) -> [InsulinDose] {
        doses(in: now.addingTimeInterval(-lookback)...now.addingTimeInterval(86400))
            .filter(\.isManual)
            .reversed()
    }

    func latestInsulinName(kind: InsulinKind, now: Date, lookback: TimeInterval = 30 * 86400) -> String? {
        doses(in: now.addingTimeInterval(-lookback)...now)
            .last { $0.kind == kind && $0.insulinName != nil }?
            .insulinName
    }
}

/// Reconciliation must see the Doses just outside the interval, or a manual Dose at its edge
/// would lose the Glooko Dose that supersedes it.
func reconciledDoses(in interval: ClosedRange<Date>, raw: (ClosedRange<Date>) -> [InsulinDose]) -> [InsulinDose] {
    let widened = interval.lowerBound.addingTimeInterval(-manualDoseMatchTolerance)...interval.upperBound.addingTimeInterval(manualDoseMatchTolerance)
    return reconcileDoses(raw(widened)).filter { interval.contains($0.timestamp) }
}

struct DoseTombstone: Codable {
    let deletedDoseId: String
}

/// LibreLinkUp and Glooko stamp the same sensor Reading a few seconds apart.
public let duplicateReadingTolerance: TimeInterval = 30

@discardableResult
func insertReading(_ reading: Reading, into sorted: inout [Reading]) -> Bool {
    let index = sorted.partitioningIndex { $0.timestamp >= reading.timestamp }
    if index < sorted.count, sorted[index].timestamp.timeIntervalSince(reading.timestamp) <= duplicateReadingTolerance {
        return false
    }
    if index > 0, reading.timestamp.timeIntervalSince(sorted[index - 1].timestamp) <= duplicateReadingTolerance {
        return false
    }
    sorted.insert(reading, at: index)
    return true
}

func readingsSlice(_ sorted: [Reading], in interval: ClosedRange<Date>) -> ArraySlice<Reading> {
    let start = sorted.partitioningIndex { $0.timestamp >= interval.lowerBound }
    let end = sorted.partitioningIndex { $0.timestamp > interval.upperBound }
    return sorted[start..<max(start, end)]
}

extension Array {
    func partitioningIndex(where belongsInSecondPartition: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsInSecondPartition(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

/// Append-only month files, so a poll writes a line rather than rewriting the whole history.
public final class FileHistoryStore: HistoryStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var readingMonths: [MonthKey: [Reading]] = [:]
    private var doseMonths: [MonthKey: [String: InsulinDose]] = [:]

    public init(directory: URL = FileHistoryStore.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The Mac app is ad-hoc signed, so the OS does not grant it the group container.
    public static func defaultDirectory() -> URL {
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sugarbarAppGroupIdentifier) {
            return group.appending(path: "History", directoryHint: .isDirectory)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Sugarbar/History", directoryHint: .isDirectory)
    }

    public func readings(in interval: ClosedRange<Date>) -> [Reading] {
        lock.withLock {
            MonthKey.covering(interval).flatMap { readingsSlice(loadedReadings($0), in: interval) }
        }
    }

    public func doses(in interval: ClosedRange<Date>) -> [InsulinDose] {
        lock.withLock {
            reconciledDoses(in: interval) { widened in
                MonthKey.covering(widened).flatMap { loadedDoses($0).values.filter { widened.contains($0.timestamp) } }
            }
        }
    }

    @discardableResult
    public func append(readings: [Reading]) -> Int {
        lock.withLock {
            var added: [MonthKey: [Reading]] = [:]
            for reading in readings.map(\.wholeSecond) {
                let key = MonthKey(reading.timestamp)
                let neighbours = Set([
                    MonthKey(reading.timestamp.addingTimeInterval(-duplicateReadingTolerance)),
                    MonthKey(reading.timestamp.addingTimeInterval(duplicateReadingTolerance)),
                ]).subtracting([key])
                if neighbours.contains(where: { isDuplicate(reading, in: loadedReadings($0)) }) { continue }
                var month = loadedReadings(key)
                if insertReading(reading, into: &month) {
                    added[key, default: []].append(reading)
                }
                readingMonths[key] = month
            }
            for (key, rows) in added {
                appendLines(rows.map(encodeReadingLine), to: readingsFile(key))
            }
            return added.values.reduce(0) { $0 + $1.count }
        }
    }

    @discardableResult
    public func append(doses: [InsulinDose]) -> Int {
        lock.withLock {
            var added: [MonthKey: [InsulinDose]] = [:]
            for dose in doses {
                let key = MonthKey(dose.timestamp)
                var month = loadedDoses(key)
                guard month[dose.id] != dose else { continue }
                month[dose.id] = dose
                doseMonths[key] = month
                added[key, default: []].append(dose)
            }
            let encoder = JSONEncoder()
            for (key, rows) in added {
                let lines = rows.compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
                appendLines(lines, to: dosesFile(key))
            }
            return added.values.reduce(0) { $0 + $1.count }
        }
    }

    public func delete(dose: InsulinDose) {
        lock.withLock {
            let key = MonthKey(dose.timestamp)
            var month = loadedDoses(key)
            guard month.removeValue(forKey: dose.id) != nil,
                  let line = try? JSONEncoder().encode(DoseTombstone(deletedDoseId: dose.id))
            else { return }
            doseMonths[key] = month
            appendLines([String(decoding: line, as: UTF8.self)], to: dosesFile(key))
        }
    }

    public func glookoCursor() -> Date? {
        guard let text = try? String(contentsOf: cursorFile, encoding: .utf8),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func setGlookoCursor(_ date: Date) {
        try? String(Int(date.timeIntervalSince1970)).write(to: cursorFile, atomically: true, encoding: .utf8)
    }

    private var cursorFile: URL { directory.appending(path: "glooko-cursor") }
    private func readingsFile(_ key: MonthKey) -> URL { directory.appending(path: "readings-\(key).tsv") }
    private func dosesFile(_ key: MonthKey) -> URL { directory.appending(path: "doses-\(key).jsonl") }

    private func isDuplicate(_ reading: Reading, in month: [Reading]) -> Bool {
        var copy = month
        return !insertReading(reading, into: &copy)
    }

    private func loadedReadings(_ key: MonthKey) -> [Reading] {
        if let cached = readingMonths[key] { return cached }
        var month: [Reading] = []
        for line in lines(of: readingsFile(key)) {
            if let reading = decodeReadingLine(line) { insertReading(reading, into: &month) }
        }
        readingMonths[key] = month
        return month
    }

    private func loadedDoses(_ key: MonthKey) -> [String: InsulinDose] {
        if let cached = doseMonths[key] { return cached }
        let decoder = JSONDecoder()
        var month: [String: InsulinDose] = [:]
        for line in lines(of: dosesFile(key)) {
            let data = Data(line.utf8)
            if let dose = try? decoder.decode(InsulinDose.self, from: data) {
                month[dose.id] = dose
            } else if let tombstone = try? decoder.decode(DoseTombstone.self, from: data) {
                month[tombstone.deletedDoseId] = nil
            }
        }
        doseMonths[key] = month
        return month
    }

    private func lines(of file: URL) -> [Substring] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    private func appendLines(_ lines: [String], to file: URL) {
        guard !lines.isEmpty else { return }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

public final class InMemoryHistoryStore: HistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReadings: [Reading] = []
    private var storedDoses: [String: InsulinDose] = [:]
    private var cursor: Date?

    public init() {}

    public func readings(in interval: ClosedRange<Date>) -> [Reading] {
        lock.withLock { Array(readingsSlice(storedReadings, in: interval)) }
    }

    public func doses(in interval: ClosedRange<Date>) -> [InsulinDose] {
        lock.withLock {
            reconciledDoses(in: interval) { widened in storedDoses.values.filter { widened.contains($0.timestamp) } }
        }
    }

    public func delete(dose: InsulinDose) {
        lock.withLock { _ = storedDoses.removeValue(forKey: dose.id) }
    }

    @discardableResult
    public func append(readings: [Reading]) -> Int {
        lock.withLock { readings.filter { insertReading($0.wholeSecond, into: &storedReadings) }.count }
    }

    @discardableResult
    public func append(doses: [InsulinDose]) -> Int {
        lock.withLock {
            doses.filter { dose in
                guard storedDoses[dose.id] != dose else { return false }
                storedDoses[dose.id] = dose
                return true
            }.count
        }
    }

    public func glookoCursor() -> Date? { lock.withLock { cursor } }
    public func setGlookoCursor(_ date: Date) { lock.withLock { cursor = date } }
}

struct MonthKey: Hashable, CustomStringConvertible {
    let year: Int
    let month: Int

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(_ date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year!, month: parts.month!)
    }

    var description: String { String(format: "%04d-%02d", year, month) }

    var next: MonthKey { month == 12 ? MonthKey(year: year + 1, month: 1) : MonthKey(year: year, month: month + 1) }

    static func covering(_ interval: ClosedRange<Date>) -> [MonthKey] {
        let last = MonthKey(interval.upperBound)
        var keys = [MonthKey(interval.lowerBound)]
        while keys.last != last, keys.count < 10_000 { keys.append(keys.last!.next) }
        return keys
    }
}

private extension Reading {
    var wholeSecond: Reading {
        Reading(value: value, timestamp: Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded()), trend: trend)
    }
}

func encodeReadingLine(_ reading: Reading) -> String {
    "\(Int(reading.timestamp.timeIntervalSince1970))\t\(reading.value)\t\(reading.trend.apiValue)"
}

func decodeReadingLine(_ line: Substring) -> Reading? {
    let fields = line.split(separator: "\t")
    guard fields.count == 3, let seconds = Int(fields[0]), let value = Double(fields[1]), let trend = Int(fields[2])
    else { return nil }
    return Reading(value: value, timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)), trend: Trend(apiValue: trend))
}
