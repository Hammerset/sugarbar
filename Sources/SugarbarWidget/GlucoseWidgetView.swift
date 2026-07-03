import SwiftUI
import WidgetKit

struct GlucoseWidgetView: View {
    let entry: GlucoseEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "sugarbar://open"))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemMedium:
            HomeScreenGlucoseView(entry: entry, showsHistory: true)
        case .accessoryCircular:
            LockScreenCircularView(entry: entry)
        case .accessoryRectangular:
            LockScreenRectangularView(entry: entry)
        case .accessoryInline:
            LockScreenInlineView(entry: entry)
        default:
            HomeScreenGlucoseView(entry: entry, showsHistory: false)
        }
    }
}
