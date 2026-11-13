import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let hosting: NSHostingController<PanelView>

    init(
        model: BarViewModel,
        onAskClaude: @escaping () -> Void,
        onLogMeal: @escaping () -> Void,
        onPlanMeal: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        let popover = popover
        hosting = NSHostingController(rootView: PanelView(
            model: model,
            onOpenSettings: { [weak popover] in
                popover?.performClose(nil)
                onOpenSettings()
            },
            onAskClaude: { [weak popover] in
                popover?.performClose(nil)
                onAskClaude()
            },
            onLogMeal: { [weak popover] in
                popover?.performClose(nil)
                onLogMeal()
            },
            onPlanMeal: { [weak popover] in
                popover?.performClose(nil)
                onPlanMeal()
            }
        ))
        hosting.sizingOptions = .preferredContentSize
        super.init()

        popover.behavior = .transient
        popover.contentViewController = hosting

        if let button = statusItem.button {
            let label = ClickThroughHostingView(rootView: BarLabel(model: model))
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                label.topAnchor.constraint(equalTo: button.topAnchor),
                label.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            // A variable-length item won't grow the button to a SwiftUI subview's
            // content, so a value wider than the launch width ("—") overlaps itself.
            // Drive the item's length from the label's own width instead.
            label.onWidthChange = { [weak statusItem] width in
                // +2 absorbs button chrome/rounding so the value never lands a point short and truncates.
                statusItem?.length = width + 2
            }
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let screen = button.window?.screen ?? NSScreen.main {
                // Room for the popover's arrow and border below the menu bar.
                hosting.rootView.maxHeight = screen.visibleFrame.height - 40
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// Declines hit-testing so clicks fall through to the status-item button, whose
/// action toggles the popover. Without this the hosting view swallows the click.
/// Also reports its content width so the controller can size the status item, since
/// a variable-length item doesn't track a SwiftUI subview's intrinsic size.
private final class ClickThroughHostingView: NSHostingView<BarLabel> {
    var onWidthChange: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = -1

    required init(rootView: BarLabel) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let width = ceil(intrinsicContentSize.width)
        guard width > 0, abs(width - lastWidth) >= 1 else { return }
        lastWidth = width
        onWidthChange?(width)
    }
}
