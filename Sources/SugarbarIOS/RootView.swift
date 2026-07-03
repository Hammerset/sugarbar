import SwiftUI

struct RootView: View {
    let model: GlucoseViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isSignedIn {
                TrendsView(model: model)
            } else {
                SignInView(model: model)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard model.isSignedIn else { return }
            if phase == .active {
                model.start()
            } else {
                model.stop()
            }
        }
    }
}
