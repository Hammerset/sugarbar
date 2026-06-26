# Menu-bar rendering: AppKit NSStatusItem, not SwiftUI MenuBarExtra

## Status

accepted

## Context

The menu bar must show a glucose number tinted with its band color plus a trend arrow. SwiftUI's `MenuBarExtra` (macOS 13+) is the modern, obvious choice and a future reader would assume we used it.

## Decision

Use AppKit `NSStatusItem` for the bar label (an `NSHostingView` of a small SwiftUI view, or an `attributedTitle` with `foregroundColor`), and present the click-through panel via an `NSPopover`/`MenuBarExtra(.window)`-style SwiftUI view hosting Swift Charts.

## Why (the non-obvious part)

`MenuBarExtra` renders its label as a monochrome **template** — it cannot reliably show multi-color text or a tinted glyph in the bar itself. Since "colored number + colored arrow" is a hard requirement, the modern API is disqualified for the label specifically. We still use SwiftUI everywhere behind the label.

## Consequences

- Dynamic label width needs manual handling (`GeometryReader` + `PreferenceKey` to size the `NSHostingView`).
- Tints must be tuned to stay legible on both light and dark menu bars.
