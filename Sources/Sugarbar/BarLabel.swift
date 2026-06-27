import SwiftUI

struct BarLabel: View {
    let model: BarViewModel

    var body: some View {
        let content = model.content
        return HStack(spacing: 2) {
            if let text = content.text {
                Text(text)
            }
            if let glyph = content.glyph {
                Image(systemName: glyph)
            }
            if let arrow = content.trendArrowText {
                Text(arrow)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(content.tint)
        .lineLimit(1)
        // Pinned to the status button's edges, the label is handed a fixed frame; without
        // this the value Text truncates ("15…") instead of reporting its full intrinsic width.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 4)
    }
}
