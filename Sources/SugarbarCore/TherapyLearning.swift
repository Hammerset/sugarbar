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
    subscript(quantity: TherapyQuantity) -> Double? {
        get { quantity == .carbRatio ? carbRatio : insulinSensitivity }
        set {
            if quantity == .carbRatio { carbRatio = newValue } else { insulinSensitivity = newValue }
        }
    }
}

public extension Settings {
    /// Suggestions the user has not dismissed; a dismissed one returns once the estimate moves
    /// more than the Suggestion margin away from the value dismissed.
    func visibleSuggestions(_ estimate: TherapyEstimate?, margin: Double = TherapyEstimationOptions.default.suggestionMargin) -> [TherapySuggestion] {
        (estimate?.suggestions ?? []).filter { suggestion in
            guard therapy[suggestion.quantity] != suggestion.suggested else { return false }
            guard let dismissed = therapyLearning.dismissed[suggestion.quantity] else { return true }
            return abs(log(suggestion.suggested / dismissed)) > log(1 + margin)
        }
    }

    func accepting(_ suggestion: TherapySuggestion, at date: Date) -> Settings {
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

    /// Saves hand-edited Therapy Settings, logging any change to sensitivity or carb ratio.
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
