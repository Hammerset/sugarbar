import SwiftUI
import WidgetKit

struct GlucoseWidget: Widget {
    let kind = "GlucoseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: GlucoseTimelineProvider()) { entry in
            GlucoseWidgetView(entry: entry)
        }
        .configurationDisplayName("Glucose")
        .description("Your latest glucose reading, Trend, and Band.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}
