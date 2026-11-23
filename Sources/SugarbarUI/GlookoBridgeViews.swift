import SwiftUI
import SugarbarCore

/// The Sync Server's Glooko bridge: on or off, and whether it is getting through.
public struct GlookoBridgeRows: View {
    private let coordinator: SyncCoordinator

    public init(coordinator: SyncCoordinator) {
        self.coordinator = coordinator
    }

    public static let note = "Your server sends eaten Meals' carbs and your manual insulin to Glooko, and removes a manual dose once its pen dose arrives. Carbs logged in the Glooko app come back as Meals."

    public var body: some View {
        Toggle("Send to Glooko", isOn: Binding(
            get: { coordinator.glooko.isSending },
            set: { coordinator.setGlookoSending($0) }
        ))
        if let line = coordinator.glooko.summaryLine {
            Text(line)
                .font(.caption)
                .foregroundStyle(coordinator.glooko.hasProblem ? .red : .secondary)
        }
        Text(Self.note)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// "In Glooko", "Waiting for Glooko" or why it is not there, under a recent Meal or manual Dose.
public struct GlookoStatusText: View {
    private let label: GlookoItemLabel

    public init?(_ status: GlookoItemStatus?, isSending: Bool) {
        guard let label = glookoItemLabel(status, isSending: isSending) else { return nil }
        self.label = label
    }

    public var body: some View {
        Text(label.isProblem ? [label.text, label.detail].compactMap(\.self).joined(separator: ": ") : label.text)
            .font(.caption2)
            .foregroundStyle(label.isProblem ? .red : .secondary)
            .lineLimit(2)
            .help(label.detail ?? label.text)
    }
}
