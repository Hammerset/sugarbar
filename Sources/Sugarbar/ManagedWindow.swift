import AppKit
import SwiftUI

/// A single lazily-created window hosting SwiftUI content. Reused across opens so the
/// app keeps at most one of each; reshowing reseeds the content with current state.
@MainActor
final class ManagedWindow {
    private var window: NSWindow?
    private let title: String

    init(title: String) {
        self.title = title
    }

    func show<Content: View>(@ViewBuilder content: () -> Content) {
        let hosting = NSHostingController(rootView: content())
        if let window {
            window.contentViewController = hosting
        } else {
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = title
            newWindow.styleMask = [.titled, .closable, .resizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}
