import SwiftUI

@main
struct SugarbarIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = GlucoseViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
