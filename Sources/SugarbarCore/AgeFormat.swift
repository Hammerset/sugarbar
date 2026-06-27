import Foundation

public func formatAge(_ age: TimeInterval) -> String {
    let seconds = Int(age)
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) min ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) h ago" }
    let days = hours / 24
    if days < 7 { return "\(days) d ago" }
    let weeks = days / 7
    return "\(weeks) w ago"
}
