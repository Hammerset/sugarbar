public enum Trend: Equatable, Sendable, Codable {
    case notDetermined
    case fallingQuickly
    case falling
    case stable
    case rising
    case risingQuickly

    public init(apiValue: Int) {
        switch apiValue {
        case 1: self = .fallingQuickly
        case 2: self = .falling
        case 3: self = .stable
        case 4: self = .rising
        case 5: self = .risingQuickly
        default: self = .notDetermined
        }
    }

    public var apiValue: Int {
        switch self {
        case .notDetermined: 0
        case .fallingQuickly: 1
        case .falling: 2
        case .stable: 3
        case .rising: 4
        case .risingQuickly: 5
        }
    }

    public var symbolName: String? {
        switch self {
        case .notDetermined: nil
        case .fallingQuickly: "arrow.down"
        case .falling: "arrow.down.right"
        case .stable: "arrow.right"
        case .rising: "arrow.up.right"
        case .risingQuickly: "arrow.up"
        }
    }

    public var arrowText: String? {
        switch self {
        case .notDetermined: nil
        case .fallingQuickly: "↓"
        case .falling: "↘"
        case .stable: "→"
        case .rising: "↗"
        case .risingQuickly: "↑"
        }
    }
}
