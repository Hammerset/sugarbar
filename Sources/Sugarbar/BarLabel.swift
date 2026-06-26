import SwiftUI

struct BarLabel: View {
    var body: some View {
        HStack(spacing: 2) {
            Text("5.3")
            Image(systemName: "arrow.up.right")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.green)
        .padding(.horizontal, 4)
    }
}
