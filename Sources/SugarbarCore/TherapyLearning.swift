import Foundation

/// One change to a working Therapy Setting, accepted from a Suggestion or typed by hand.
public struct TherapyChange: Equatable, Sendable, Codable, Identifiable {
    public let id: UUID
    public let date: Date
    public let quantity: TherapyQuantity
    public let old: Double?
    public let new: Double?
    public let evidence: String

    public init(id: UUID = UUID(), date: Date, quantity: TherapyQuantity, old: Double?, new: Double?, evidence: String) {
        self.id = id
        self.date = date
        self.quantity = quantity
        self.old = old
        self.new = new
        self.evidence = evidence
    }
}

/// What the user did with Suggestions: the Change Log, and the value last dismissed per quantity.
public struct TherapyLearning: Equatable, Sendable, Codable {
    public var changes: [TherapyChange]
    public var dismissed: [TherapyQuantity: Double]

    public init(changes: [TherapyChange] = [], dismissed: [TherapyQuantity: Double] = [:]) {
        self.changes = changes
        self.dismissed = dismissed
    }

    public static let `default` = TherapyLearning()
    static let maximumChanges = 50

    mutating func record(_ change: TherapyChange) {
        changes = Array((changes + [change]).suffix(Self.maximumChanges))
    }
}

public extension TherapySettings {
    /// Setting a timing or factor to nil leaves it unchanged: only sensitivity and carb ratio can be unset.
    subscript(quantity: TherapyQuantity) -> Double? {
        get {
            switch quantity {
            case .insulinSensitivity: insulinSensitivity
            case .carbRatio: carbRatio
            case .insulinPeak: insulinPeak
            case .insulinDuration: insulinDuration
            case .fastCarbAbsorption: fastCarbAbsorptionTime
            case .normalCarbAbsorption: carbAbsorptionTime
            case .slowCarbAbsorption: slowCarbAbsorptionTime
            case .trendBlend: trendBlendDuration
            case .slowestCarbFactor: slowestCarbFactor
            case .fastestCarbFactor: fastestCarbFactor
            }
        }
        set {
            switch quantity {
            case .insulinSensitivity: insulinSensitivity = newValue
            case .carbRatio: carbRatio = newValue
            default:
                guard let newValue else { return }
                switch quantity {
                case .insulinPeak: insulinPeak = newValue
                case .insulinDuration: insulinDuration = newValue
                case .fastCarbAbsorption: fastCarbAbsorptionTime = newValue
                case .normalCarbAbsorption: carbAbsorptionTime = newValue
                case .slowCarbAbsorption: slowCarbAbsorptionTime = newValue
                case .trendBlend: trendBlendDuration = newValue
                case .slowestCarbFactor: slowestCarbFactor = newValue
                case .fastestCarbFactor: fastestCarbFactor = newValue
                case .insulinSensitivity, .carbRatio: break
                }
            }
        }
    }
}

public extension Settings {
    /// Suggestions the user has not dismissed; a dismissed one returns once the estimate moves
    /// more than the Suggestion margin away from the value dismissed.
    func visibleSuggestions(
        _ estimate: TherapyEstimate?,
        forecastLearning: ForecastLearning? = nil,
        margin: Double = TherapyEstimationOptions.default.suggestionMargin
    ) -> [TherapySuggestion] {
        let forecastSuggestions = (forecastLearning?.suggestions ?? []).filter { therapy.isValidAccepting($0) }
        return ((estimate?.suggestions ?? []) + forecastSuggestions).filter { suggestion in
            guard therapy[suggestion.quantity] != suggestion.suggested else { return false }
            guard let dismissed = therapyLearning.dismissed[suggestion.quantity] else { return true }
            return abs(log(suggestion.suggested / dismissed)) > log(1 + margin)
        }
    }

    func accepting(_ suggestion: TherapySuggestion, at date: Date) -> Settings {
        guard therapy.isValidAccepting(suggestion) else { return self }
        var updated = self
        updated.therapy[suggestion.quantity] = suggestion.suggested
        updated.therapyLearning.dismissed[suggestion.quantity] = nil
        updated.therapyLearning.record(TherapyChange(
            date: date,
            quantity: suggestion.quantity,
            old: therapy[suggestion.quantity],
            new: suggestion.suggested,
            evidence: "Suggested from \(suggestion.evidence)"
        ))
        return updated
    }

    func dismissing(_ suggestion: TherapySuggestion) -> Settings {
        var updated = self
        updated.therapyLearning.dismissed[suggestion.quantity] = suggestion.suggested
        return updated
    }

    /// Saves hand-edited Therapy Settings, logging every changed value.
    func editingTherapy(_ edited: TherapySettings, at date: Date) -> Settings {
        var updated = self
        updated.therapy = edited
        for quantity in TherapyQuantity.allCases where therapy[quantity] != edited[quantity] {
            updated.therapyLearning.record(TherapyChange(
                date: date,
                quantity: quantity,
                old: therapy[quantity],
                new: edited[quantity],
                evidence: "Entered by hand"
            ))
        }
        return updated
    }
}

extension TherapySettings {
    /// A forecast parameter Suggestion made against other values can break the settings' own rules.
    func isValidAccepting(_ suggestion: TherapySuggestion) -> Bool {
        var updated = self
        updated[suggestion.quantity] = suggestion.suggested
        return updated.isValid
    }
}
