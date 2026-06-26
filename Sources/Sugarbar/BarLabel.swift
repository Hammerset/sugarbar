import SwiftUI

struct BarLabel: View {
    let model: BarViewModel

    var body: some View {
        HStack(spacing: 2) {
            Text(model.displayValue)
            if let symbol = model.trendSymbolName {
                Image(systemName: symbol)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(model.isStale ? Color.secondary : (model.band?.tint ?? .primary))
        .padding(.horizontal, 4)
    }
}
