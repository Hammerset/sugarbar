# sugarbar

A native macOS menu-bar app that shows your FreeStyle Libre 3 glucose — latest value + trend, colour-coded against a 5-band reference scale, with a recent-history graph in a click-through panel.

Reads from the unofficial **LibreLinkUp** API as a Follower. A LibreLinkUp account that receives a share from the phone running the Libre app is a prerequisite.

> Not a medical device. For informational use only. See `CONTEXT.md` for the domain language; roadmap and design decisions live in [GitHub issues](https://github.com/Hammerset/sugarbar/issues) (decisions are labelled `decision`).

## Requirements

- macOS 15 (Sequoia) or later
- Swift 6 toolchain (ships with Xcode 16+, or the standalone Swift toolchain). Check with `swift --version`.
- A LibreLinkUp account already sharing data from a Primary phone.

## Build

```sh
swift build
```

## Run

The app launches as a menu-bar agent (no Dock icon). A colour-coded glucose number appears in the menu bar; click it for the history panel and **Settings**.

### From source (development)

```sh
swift run Sugarbar
```

Open **Settings** from the panel and sign in with your LibreLinkUp email + password — they're stored in the Keychain, so you only do this once. Leave the terminal running; quitting it stops the app. To stop, quit from the panel or press `Ctrl-C`.

For a quick start without the UI, you can pass credentials inline. Environment variables take precedence over the Keychain:

```sh
SUGARBAR_LIBRE_EMAIL="you@example.com" \
SUGARBAR_LIBRE_PASSWORD="your-librelinkup-password" \
swift run Sugarbar
```

### As a packaged app (recommended)

```sh
packaging/package.sh
```

Builds a release binary and wraps it in an ad-hoc-signed `Sugarbar.app` (with the app icon) under `dist/`. It's for personal use — not notarized, not for distribution. Install it so launch-at-login sticks:

```sh
cp -R dist/Sugarbar.app /Applications/
```

Then open it, click the menu-bar item, open **Settings**, and sign in. The launch-at-login toggle only works from the packaged app.

If no credentials are set, the bar shows `—` and the panel reads *"Open Settings to sign in"*.

## Test

```sh
swift test
```

## Project layout

| Path | What |
|---|---|
| `Sources/SugarbarCore/` | Source-agnostic domain + the LibreLinkUp client (auth, region redirect, fetch, polling, staleness). No AppKit. |
| `Sources/Sugarbar/` | The macOS app: menu-bar item, SwiftUI panel, settings, view model, app lifecycle. |
| `Tests/SugarbarCoreTests/` | Unit tests for the core, against recorded API responses. |
| `packaging/` | `package.sh` (build the `.app`), `Info.plist`, and `icon/` — the CoreGraphics source that renders `AppIcon.icns`. |

## Notes

- **Units:** the API returns mg/dL; the app converts to mmol/L (one decimal).
- **App icon:** generated from Swift/CoreGraphics in `packaging/icon/`. Regenerate with `packaging/icon/build-icns.sh`.
- **Build artifacts:** `swift build` writes to `.build/`, `package.sh` to `dist/` (both git-ignored).
- **API churn:** this rides an undocumented API. If Abbott bumps the LibreLinkUp app version, calls may start failing (`430`) until the `version` header in `LibreLinkUpClient` is updated.
