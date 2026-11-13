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
        if let window { fitOnScreen(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func fitOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    func close() {
        window?.close()
    }
}
