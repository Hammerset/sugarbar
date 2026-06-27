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
            if let symbol = content.trendSymbol {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(content.tint)
        .padding(.horizontal, 4)
    }
}
