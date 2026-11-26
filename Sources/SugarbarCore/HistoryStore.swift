import Foundation

/// Never pruned. Readings are de-duplicated by time; Doses by `id`, the latest copy winning.
/// `doses(in:)` is already reconciled: a manual Dose superseded by its Glooko Dose is left out.
public protocol HistoryStore: AnyObject, Sendable {
    func readings(in interval: ClosedRange<Date>) -> [Reading]
    func doses(in interval: ClosedRange<Date>) -> [InsulinDose]
    @discardableResult func append(readings: [Reading]) -> Int
    @discardableResult func append(doses: [InsulinDose]) -> Int
    func delete(dose: InsulinDose)
    /// Every stored Dose, not reconciled: a superseded manual Dose is still here.
    func allDoses() -> [InsulinDose]
    /// Doses deleted and not stored again since. Deletions recorded before they carried a time are left out.
    func doseDeletions() -> [DoseDeletion]
    func earliestReadingDate() -> Date?
    func glookoCursor() -> Date?
    func setGlookoCursor(_ date: Date)
    func lastGlookoReread() -> Date?
    func setLastGlookoReread(_ date: Date)
    func glookoEchoes() -> Set<GlookoEcho>
    func setGlookoEchoes(_ echoes: Set<GlookoEcho>)
}

public extension HistoryStore {
    /// Delete-then-append, so an edit that moves a Dose into another month leaves no copy behind.
    func replace(_ old: InsulinDose, with new: InsulinDose) {
        delete(dose: old)
        append(doses: [new])
    }

    /// Glooko is the source of truth for its Doses: those stored in `interval` that `fetched` lacks were
    /// deleted or changed in Glooko (a pen dose marked as priming drops out of its insulin series).
    @discardableResult
    func removeGlookoDoses(in interval: ClosedRange<Date>, missingFrom fetched: [InsulinDose]) -> [InsulinDose] {
        let kept = Set(fetched.map(\.id))
        let gone = allDoses().filter { !$0.isManual && interval.contains($0.timestamp) && !kept.contains($0.id) }
        for dose in gone { delete(dose: dose) }
        return gone
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
func reconciledDoses(in interval: ClosedRange<Date>, echoes: Set<GlookoEcho>, raw: (ClosedRange<Date>) -> [InsulinDose]) -> [InsulinDose] {
    let widened = interval.lowerBound.addingTimeInterval(-manualDoseMatchTolerance)...interval.upperBound.addingTimeInterval(manualDoseMatchTolerance)
    return reconcileDoses(raw(widened), echoes: echoes).filter { interval.contains($0.timestamp) }
}

public struct DoseDeletion: Equatable, Sendable {
    public let id: String
    public let timestamp: Date

    public var isManual: Bool { id.hasPrefix(manualDoseIdPrefix) }
}

struct DoseTombstone: Codable {
    let deletedDoseId: String
    let timestamp: Date?
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
    private var deletionMonths: [MonthKey: [String: Date]] = [:]
    private var echoes: Set<GlookoEcho>?

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
            reconciledDoses(in: interval, echoes: loadedEchoes()) { widened in
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
                deletionMonths[key]?[dose.id] = nil
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
                  let line = try? JSONEncoder().encode(DoseTombstone(deletedDoseId: dose.id, timestamp: dose.timestamp))
            else { return }
            doseMonths[key] = month
            deletionMonths[key, default: [:]][dose.id] = dose.timestamp
            appendLines([String(decoding: line, as: UTF8.self)], to: dosesFile(key))
        }
    }

    public func allDoses() -> [InsulinDose] {
        lock.withLock {
            storedMonths(prefix: "doses-").flatMap { loadedDoses($0).values }.chronological()
        }
    }

    public func doseDeletions() -> [DoseDeletion] {
        lock.withLock {
            storedMonths(prefix: "doses-").flatMap { key in
                _ = loadedDoses(key)
                return (deletionMonths[key] ?? [:]).map { DoseDeletion(id: $0.key, timestamp: $0.value) }
            }
            .sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        }
    }

    public func earliestReadingDate() -> Date? {
        lock.withLock {
            storedMonths(prefix: "readings-").lazy.compactMap { self.loadedReadings($0).first?.timestamp }.first
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

    public func lastGlookoReread() -> Date? {
        guard let text = try? String(contentsOf: rereadFile, encoding: .utf8),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public func setLastGlookoReread(_ date: Date) {
        try? String(Int(date.timeIntervalSince1970)).write(to: rereadFile, atomically: true, encoding: .utf8)
    }

    private var rereadFile: URL { directory.appending(path: "glooko-reread") }

    public func glookoEchoes() -> Set<GlookoEcho> {
        lock.withLock { loadedEchoes() }
    }

    public func setGlookoEchoes(_ echoes: Set<GlookoEcho>) {
        lock.withLock {
            self.echoes = echoes
            if let data = try? JSONEncoder().encode(echoes.sorted { ($0.t, $0.kind.rawValue, $0.units) < ($1.t, $1.kind.rawValue, $1.units) }) {
                try? data.write(to: echoesFile, options: .atomic)
            }
        }
    }

    private var echoesFile: URL { directory.appending(path: "glooko-echoes.json") }

    private func loadedEchoes() -> Set<GlookoEcho> {
        if let echoes { return echoes }
        let loaded = (try? Data(contentsOf: echoesFile)).flatMap { try? JSONDecoder().decode(Set<GlookoEcho>.self, from: $0) } ?? []
        echoes = loaded
        return loaded
    }

    private func readingsFile(_ key: MonthKey) -> URL { directory.appending(path: "readings-\(key).tsv") }
    private func dosesFile(_ key: MonthKey) -> URL { directory.appending(path: "doses-\(key).jsonl") }

    private func storedMonths(prefix: String) -> [MonthKey] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let cached = prefix == "doses-" ? Array(doseMonths.keys) : Array(readingMonths.keys)
        let onDisk = names.compactMap { name -> MonthKey? in
            guard name.hasPrefix(prefix), let dot = name.lastIndex(of: ".") else { return nil }
            return MonthKey(String(name[name.index(name.startIndex, offsetBy: prefix.count)..<dot]))
        }
        return Set(onDisk + cached).sorted { ($0.year, $0.month) < ($1.year, $1.month) }
    }

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
        var deletions: [String: Date] = [:]
        for line in lines(of: dosesFile(key)) {
            let data = Data(line.utf8)
            if let dose = try? decoder.decode(InsulinDose.self, from: data) {
                month[dose.id] = dose
                deletions[dose.id] = nil
            } else if let tombstone = try? decoder.decode(DoseTombstone.self, from: data) {
                month[tombstone.deletedDoseId] = nil
                deletions[tombstone.deletedDoseId] = tombstone.timestamp
            }
        }
        doseMonths[key] = month
        deletionMonths[key] = deletions
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
    private var deletions: [String: Date] = [:]
    private var cursor: Date?
    private var reread: Date?
    private var echoes: Set<GlookoEcho> = []

    public init() {}

    public func readings(in interval: ClosedRange<Date>) -> [Reading] {
        lock.withLock { Array(readingsSlice(storedReadings, in: interval)) }
    }

    public func doses(in interval: ClosedRange<Date>) -> [InsulinDose] {
        lock.withLock {
            reconciledDoses(in: interval, echoes: echoes) { widened in storedDoses.values.filter { widened.contains($0.timestamp) } }
        }
    }

    public func delete(dose: InsulinDose) {
        lock.withLock {
            guard storedDoses.removeValue(forKey: dose.id) != nil else { return }
            deletions[dose.id] = dose.timestamp
        }
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
                deletions[dose.id] = nil
                return true
            }.count
        }
    }

    public func allDoses() -> [InsulinDose] {
        lock.withLock { storedDoses.values.chronological() }
    }

    public func doseDeletions() -> [DoseDeletion] {
        lock.withLock { deletions.map { DoseDeletion(id: $0.key, timestamp: $0.value) }.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) } }
    }

    public func earliestReadingDate() -> Date? { lock.withLock { storedReadings.first?.timestamp } }

    public func glookoCursor() -> Date? { lock.withLock { cursor } }
    public func setGlookoCursor(_ date: Date) { lock.withLock { cursor = date } }
    public func lastGlookoReread() -> Date? { lock.withLock { reread } }
    public func setLastGlookoReread(_ date: Date) { lock.withLock { reread = date } }
    public func glookoEchoes() -> Set<GlookoEcho> { lock.withLock { echoes } }
    public func setGlookoEchoes(_ echoes: Set<GlookoEcho>) { lock.withLock { self.echoes = echoes } }
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

    init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    var description: String { String(format: "%04d-%02d", year, month) }

    var start: Date { Self.calendar.date(from: DateComponents(year: year, month: month, day: 1))! }

    /// Every instant in the month; the History stores whole seconds.
    var interval: ClosedRange<Date> { start...next.start.addingTimeInterval(-0.001) }

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
