import SwiftUI

struct BarLabel: View {
    let model: BarViewModel

    var body: some View {
        Text(model.displayValue)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
    }
}
