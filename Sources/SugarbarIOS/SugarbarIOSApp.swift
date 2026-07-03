import SwiftUI

@main
struct SugarbarIOSApp: App {
    @State private var model = GlucoseViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
