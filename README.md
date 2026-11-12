# sugarbar

A native macOS menu-bar app — and a minimal iOS companion app — that shows your FreeStyle Libre 3 glucose: latest value + trend, colour-coded against a 5-band reference scale, with a recent-history graph in a click-through panel (macOS) or a full-screen reading (iOS).

Reads from the unofficial **LibreLinkUp** API as a Follower. A LibreLinkUp account that receives a share from the phone running the Libre app is a prerequisite.

Optionally overlays insulin doses from a **Glooko** account — connected-pen boluses and manually logged basal — as markers along the history graph, with per-window bolus/basal totals. This rides Glooko's internal web API (no public API exists), so it's best-effort too.

The iOS app can also log **meals** from a photo: Claude (Sonnet 5.5, via your own pay-per-use API key) estimates the carbohydrates, you review and adjust the grams, and the meal is saved alongside the glucose history and written to Apple Health. Meals show as markers on the graph on both platforms.

Both apps can optionally post **low/high alerts** as local notifications (off by default; see [Alerts](#alerts)).

A pure **forecast** module in the core predicts where glucose is heading over the next 3 hours from recent readings, bolus doses and meals (Loop-style insulin activity curve, linear carb absorption, short-term momentum). It needs your personal therapy settings — insulin sensitivity and carb ratio, entered under **Therapy Settings** on Mac or iPhone — and stays off until both are set. It is informational and never suggests a dose.

> Not a medical device. For informational use only. See `CONTEXT.md` for the domain language; roadmap and design decisions live in [GitHub issues](https://github.com/Hammerset/sugarbar/issues) (decisions are labelled `decision`).

## Requirements

- macOS 15 (Sequoia) or later; iOS 26 or later for the iPhone app
- Xcode 26+ (the apps build as Xcode targets). Check with `xcodebuild -version`.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`. The `Sugarbar.xcodeproj` is generated from `project.yml` and is **not** committed.
- A LibreLinkUp account already sharing data from a Primary phone.

## Build

The macOS and iOS apps are Xcode targets; `SugarbarCore`/`SugarbarUI` stay a SwiftPM package that both app targets (and, later, the widget) consume.

```sh
xcodegen generate        # writes Sugarbar.xcodeproj from project.yml
open Sugarbar.xcodeproj   # then build & run the Sugarbar (macOS) or SugarbarIOS scheme
```

The shared core builds and tests on its own with plain SwiftPM — no Xcode project needed (this is what CI runs):

```sh
swift build   # builds SugarbarCore
swift test    # runs the core's tests
```

## Run

The app launches as a menu-bar agent (no Dock icon). A colour-coded glucose number appears in the menu bar; click it for the history panel and **Settings**.

### From source (development)

Open `Sugarbar.xcodeproj` in Xcode (after `xcodegen generate`) and run the **Sugarbar** scheme.

Open **Settings** from the panel and sign in with your LibreLinkUp email + password — they're stored in the Keychain, so you only do this once. The **Glooko Account** section is optional: sign in there to see insulin doses on the graph (`SUGARBAR_GLOOKO_EMAIL` / `SUGARBAR_GLOOKO_PASSWORD` work the same way as the Libre variables below).

For a quick start without the UI, you can pass credentials inline. Environment variables take precedence over the Keychain — set them in the **Sugarbar** scheme's Run arguments in Xcode, or build a packaged app and run its binary directly:

```sh
packaging/package.sh
SUGARBAR_LIBRE_EMAIL="you@example.com" \
SUGARBAR_LIBRE_PASSWORD="your-librelinkup-password" \
dist/Sugarbar.app/Contents/MacOS/Sugarbar
```

### As a packaged app (recommended)

```sh
packaging/package.sh
```

Generates the project, builds a release binary, and wraps it in an ad-hoc-signed `Sugarbar.app` (with the app icon and App Group entitlement) under `dist/`. It's for personal use — not notarized, not for distribution. Install it so launch-at-login sticks:

```sh
cp -R dist/Sugarbar.app /Applications/
```

Then open it, click the menu-bar item, open **Settings**, and sign in. The launch-at-login toggle only works from the packaged app.

If no credentials are set, the bar shows `—` and the panel reads *"Open Settings to sign in"*.

### iOS app

Open `Sugarbar.xcodeproj` (after `xcodegen generate`) and run the **SugarbarIOS** scheme on a simulator or device.

To install on a physical device, first select your (paid) team in the `SugarbarIOS` target's Signing & Capabilities tab — signing is already set to Automatic, it just needs a team. Without a paid team, Xcode's free personal-team provisioning expires after 7 days.

To log meals, open **Meals** on the Trends screen and paste a Claude API key (from console.anthropic.com); it's stored in the phone's Keychain. `SUGARBAR_ANTHROPIC_API_KEY` in the scheme's Run arguments overrides it. The first meal save asks for Apple Health write access.

The app polls continuously while in the foreground; it signs in with its own LibreLinkUp credentials (Keychain is app-private, per target) and, on each successful poll, writes the shared App Group snapshot and asks WidgetKit to reload, feeding the Home Screen / Lock Screen widget. In the background it also registers a `BGAppRefreshTask` to top up the snapshot between foreground sessions — iOS gives no guaranteed cadence for this, so treat it as a best-effort bonus, not a reliable refresh (see #27, #31).

## Alerts

Off by default. Turn them on in **Settings → Alerts** (Mac) or the bell button on the Trends screen (iOS); the first time asks for notification permission. Lows (urgent low and low) are on once alerts are enabled; highs are opt-in per level.

- An alert fires when a fresh Reading enters an enabled Band, and again when it moves from low to urgent low (or high to urgent high).
- While glucose stays out of range it repeats every 20 min for lows and 60 min for highs (adjustable). Coming back into range resets it and withdraws the delivered notification.
- No alert on a stale Reading or during sensor warm-up; a gap in data neither alerts nor counts as back in range.
- **Snooze for 1 hour** silences everything until it expires.

Alerts are evaluated after each poll, so they are only as timely as polling: on iOS that means while the app is open plus the best-effort background refresh, which iOS may delay or skip for hours. Keep the Libre app's own alarms on. Alert settings live in the shared App Group settings (so they follow you across Mac and phone once the App Group is granted); each app keeps its own record of what it has already alerted on.

On iOS, lows and urgent levels use the time-sensitive interruption level so they can break through a Focus. That needs the **Time Sensitive Notifications** capability on the app's identifier: with Automatic signing, add it under Signing & Capabilities (the entitlement is already in `SugarbarIOS.entitlements`). The Mac app posts at the default level; its ad-hoc-signed build can't carry that restricted entitlement.

## Test

```sh
swift test
```

## Project layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec for the Xcode project — the macOS app, iOS app, and widget extension targets. The `.xcodeproj` is generated from this, not committed. |
| `Package.swift` | SwiftPM package exposing the `SugarbarCore`/`SugarbarUI` libraries consumed by both app targets. Source of truth for the core; `swift test` runs against it. |
| `Sources/SugarbarCore/` | Source-agnostic domain + the LibreLinkUp client (auth, region redirect, fetch, polling, staleness), the Glooko client (web sign-in, dose fetch), and the meal analyzer (one Claude Messages API call, lenient JSON parsing). No AppKit/UIKit. |
| `Sources/SugarbarUI/` | Shared SwiftUI presentation (band colours, `BarContent` text/glyph/tint, the history chart, alert settings rows) and notification delivery for alerts, consumed by both app targets. |
| `Sources/Sugarbar/` | The macOS app: menu-bar item, SwiftUI panel, settings, view model, app lifecycle. Built by the `Sugarbar` Xcode target. |
| `Sources/SugarbarIOS/` | The iOS app: sign-in, foreground polling, best-effort `BGAppRefreshTask` background top-up, current-reading screen, meal photo logging (camera/library, Claude estimate, review, HealthKit write), App Group snapshot + WidgetKit reload. Built by the `SugarbarIOS` Xcode target. |
| `Sources/SugarbarWidget/` | The WidgetKit extension: Home Screen (`systemSmall`/`systemMedium`, full colour) and Lock Screen (`accessoryCircular`/`accessoryRectangular`/`accessoryInline`, band conveyed by gauge fill/shape) glucose widgets. Reads the App Group snapshot only — no networking. Built by the `SugarbarWidget` Xcode target, embedded in `SugarbarIOS`. |
| `Tests/SugarbarCoreTests/` | Unit tests for the core, against recorded API responses. |
| `packaging/` | `package.sh` (build the macOS `.app`), `Info.plist`/`Sugarbar.entitlements` (macOS), `SugarbarIOS-Info.plist`/`SugarbarIOS.entitlements` (iOS) and `SugarbarWidget-Info.plist`/`SugarbarWidget.entitlements` (widget extension, both App Group), and `icon/` — the CoreGraphics source that renders `AppIcon.icns`. |

## Notes

- **Units:** the API returns mg/dL; the app converts to mmol/L (one decimal).
- **App icon:** generated from Swift/CoreGraphics in `packaging/icon/`. Regenerate with `packaging/icon/build-icns.sh`.
- **Build artifacts:** `Sugarbar.xcodeproj` is generated by `xcodegen` (git-ignored — regenerate with `xcodegen generate`); `swift build`/`xcodebuild` write to `.build/`, `package.sh` to `dist/` (all git-ignored).
- **App Group & signing:** the macOS app, the iOS app, and the widget extension all declare the `group.com.sugarbar` App Group so they can share the latest snapshot and settings. The macOS app's `package.sh` ad-hoc-signs, which embeds the entitlement but the OS won't *grant* the shared container until the app is signed with a real team — add a (free) Apple ID team in Xcode and switch the target to automatic signing when the macOS side needs it too ([#3](https://github.com/Hammerset/sugarbar/issues/3)). The iOS and widget targets already use Automatic signing; they just need a paid team selected in Signing & Capabilities to install on a device without the 7-day free-provisioning expiry.
- **Credentials are per-app:** each app target keeps its own LibreLinkUp Keychain entry (Phase 1, [#23](https://github.com/Hammerset/sugarbar/issues/23)) — signing in on the Mac app doesn't sign in the iOS app, and vice versa. Settings (thresholds, poll cadence, selected connection) and the latest snapshot *are* shared via the App Group.
- **API churn:** this rides an undocumented API. If Abbott bumps the LibreLinkUp app version, calls may start failing (`430`) until the `version` header in `LibreLinkUpClient` is updated. Likewise `GlookoClient` scrapes the Glooko web app's sign-in form and calls its dashboard JSON endpoint; a Glooko web redesign can break it.
- **Meals:** stored as JSON in the App Group (`shared.meals`) — that is what the graph reads on both platforms. Each saved meal is also written to Apple Health as a `dietaryCarbohydrates` sample; Health is write-only and Glooko does not import carbs from Health, so meals never reach Glooko.
- **Forecast:** `forecast(readings:doses:meals:therapy:thresholds:sensorActivation:now:)` in `SugarbarCore/Forecast.swift`. Insulin follows Loop's exponential model (default peak 75 min, duration 6 h), each meal absorbs linearly over the carb absorption time (default 3 h) at sensitivity ÷ carb ratio mmol/L per gram, and the slope of the last 15 minutes of readings replaces those effects at first and fades out over 30 minutes. Basal is ignored. Therapy settings are stored with the other settings in the App Group.
- **Dose timing:** Glooko only learns about a pen dose when the pen is synced to the Glooko app over NFC, so doses show up with that delay. Glooko is polled every 5 minutes, not on the sensor cadence.
