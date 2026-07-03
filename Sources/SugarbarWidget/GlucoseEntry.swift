import SugarbarCore
import WidgetKit

struct GlucoseEntry: TimelineEntry {
    let date: Date
    let content: BarContent
    let latest: Reading?
    let history: [Reading]
    let thresholds: Thresholds
}
