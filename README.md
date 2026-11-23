# sugarbar

A native macOS menu-bar app — and a minimal iOS companion app — that shows your FreeStyle Libre 3 glucose: latest value + trend, colour-coded against a 5-band reference scale, with a history graph in a click-through panel (macOS) or a full-screen reading (iOS).

Every poll is kept in a local history, so the graph goes back further than the ~12 hours LibreLinkUp returns: pick a range from 4 hours to 90 days, with time-in-range per band for the selected range on both platforms.

Reads from the unofficial **LibreLinkUp** API as a Follower. A LibreLinkUp account that receives a share from the phone running the Libre app is a prerequisite.

Optionally overlays insulin doses from a **Glooko** account — connected-pen boluses and manually logged basal — as markers along the history graph, with per-range bolus/basal totals. Because a pen dose only reaches Glooko once the pen is scanned, a dose can also be **entered by hand** right after injecting (amount, bolus or basal, time, insulin name) on the iPhone's Trends screen or from the syringe button in the Mac panel; when the same dose later arrives from Glooko it replaces the hand-entered one. Before a bolus is saved while more than 2 u of insulin is still on board, or within 2 h of the previous bolus, the entry form shows a **stacking warning**: insulin on board, the previous bolus, how far that insulin is still expected to lower glucose and how far carbs still being absorbed will raise it (with your insulin sensitivity and carb ratio), current glucose and trend, and where glucose would end with the new dose added, in orange when that is below your low threshold, and a caution about correcting during a post-meal rise. Saving stays one tap (**Save Anyway**); both limits are under Dose Settings. Glooko also holds the LibreLink CGM stream, so signing in backfills the history with the past 90 days of readings and doses, and keeps filling any gaps from times the app wasn't running. This rides Glooko's internal web API (no public API exists), so it's best-effort too.

Both apps can also log **meals** from a photo, a text description, or both: Claude (Sonnet 5.5, via your own pay-per-use API key) estimates the carbohydrates (plus fat, protein, energy and how fast the meal is likely to absorb, shown smaller), you review and adjust the grams and time, and the meal is saved alongside the glucose history with both Claude's figure and yours. You can also skip Claude and type the grams yourself, and edit or delete recent meals. On the iPhone, photos come from the camera or library and each eaten meal is also written to Apple Health as carbohydrates, plus fat, protein and energy when known (edits and deletes update the Health samples). On the Mac, **Log Meal** in the panel opens a window that takes a photo from a file, drag and drop, the clipboard, or **Import from iPhone** (Continuity Camera); Mac meals are not written to Apple Health. With [Sync](#sync) turned on, meals logged on one device appear on the other. Meals show as markers on the graph on both platforms.

**Plan Meal** (both apps): before eating, describe the meal (a photo is optional) and get the carb Estimate, a **Suggested Dose** and, with an API key, a **strategy** from Claude. The app computes the dose and shows every part: carbs ÷ carb ratio, plus (current glucose − target) ÷ insulin sensitivity, minus insulin on board, never below zero, capped at your maximum single dose and rounded down to the pen step. There is no suggestion without therapy settings, from a stale Reading, during sensor warm-up or at LO/HI, and when glucose is low the app says to treat the low first. Claude (Opus 5.5) then says when to inject relative to eating, whether to split the dose for a slow, fatty meal, what to watch for and when to check again; it may recommend a different amount only with a stated reason, and both amounts are then shown side by side. You change any number, then **Log dose** (prefilled; for a split, the first part now and the rest shown as a reminder on the plan) or **Save as Plan**. At the table, **Eating Now** on the plan turns it into the eaten meal, where you log what was actually eaten. Target glucose, pen step (1 or 0.5 u) and maximum single dose are under **Dose Settings** (iPhone) and **Settings → Dose Suggestion** (Mac).

**Ask Claude** (both apps, opt-in with the same API key): a chat about your recent data. The app sends Claude (Opus 5.5) a compact summary of the last 14 days of History, Doses, Meals, thresholds and therapy settings, and you ask questions such as what happened after your last meal or when you tend to go low. Answers are observations and things to discuss with your care team; Claude may discuss dose amounts with reference to the app's dose calculation and your working ratio and sensitivity, and says how uncertain they are. See [Ask Claude](#ask-claude).

Optionally, both apps **sync** Meals, Doses, Readings and settings through a small server you host yourself, so what you log on the phone shows on the Mac and the other way round. Off unless you set it up; each device keeps working offline. See [Sync](#sync).

Both apps can optionally post **low/high alerts** as local notifications (off by default; see [Alerts](#alerts)).

A pure **forecast** module in the core predicts where glucose is heading, and where it settles, from recent readings, bolus doses and meals (Loop-style insulin activity curve, linear carb absorption per meal speed, short-term momentum from the CGM trend, and a retrospective correction of carb absorption). It needs your personal therapy settings — insulin sensitivity and carb ratio, entered under **Therapy Settings** on Mac or iPhone — and stays off until both are set. Once set, the graph continues the line dashed for the next 3 hours on the 4h–24h ranges, inside a shaded uncertainty range that widens with time and when the CGM trend disagrees with the model (then "Forecast uncertain: trend differs from model" shows too), insulin on board and carbs on board show next to the current reading, and alerts can warn early when glucose is heading low or high. The forecast itself is informational; the Suggested Dose under Plan Meal is a separate calculation.

Sensitivity and carb ratio drift from week to week, so the apps also **learn them from your History** and suggest updates ("Carb ratio looks closer to 1 u per 8 g (now 10), from 6 meals in the last 10 days") on the Trends screen, the Mac panel and the Therapy Settings screen, with Accept / Dismiss. Nothing changes until you accept. See [Learned Therapy Settings](#learned-therapy-settings).

The Forecast also **keeps score of itself**: each device logs what it predicted, the details area shows how far off it has been ("Forecast accuracy, last 14 days: ±0.9 mmol/L at 30 min, ±1.6 at 60 min; 5 of 6 low warnings right", tap for the breakdown), and replaying past Forecasts suggests better insulin timing, per-speed meal absorption times and forecast tuning ("Your insulin seems to peak around 60 min, not 75 min, from 21 corrections in the last 28 days"), through the same Accept / Dismiss. See [Forecast feedback](#forecast-feedback).

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

The iOS app and widget sign automatically with the owner's paid team (`DEVELOPMENT_TEAM` in `project.yml`); to build with another team, change it there (or in Signing & Capabilities). A free personal team works too, but its provisioning expires after 7 days.

To install on a physical device, either pick the iPhone as the run destination in Xcode and run, or build and install from the command line:

```sh
xcodegen generate
xcodebuild -project Sugarbar.xcodeproj -scheme SugarbarIOS -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath .build/ios \
  -allowProvisioningUpdates build
xcrun devicectl list devices    # find the iPhone's identifier
xcrun devicectl device install app --device <udid> .build/ios/Build/Products/Debug-iphoneos/Sugarbar.app
```

To log meals, tap **Log Meal** in the Meals card on the Trends screen. For Claude's Estimate, add a Claude API key (from console.anthropic.com) in the same card; it's stored in the phone's Keychain. `SUGARBAR_ANTHROPIC_API_KEY` in the scheme's Run arguments overrides it. Without a key you can still type the grams. The first meal save asks for Apple Health write access. On the Mac, the key goes in **Settings → Claude API Key**.

The app polls continuously while in the foreground; it signs in with its own LibreLinkUp credentials (Keychain is app-private, per target) and, on each successful poll, writes the shared App Group snapshot and asks WidgetKit to reload, feeding the Home Screen / Lock Screen widget. In the background it also registers a `BGAppRefreshTask` to top up the snapshot between foreground sessions — iOS gives no guaranteed cadence for this, so treat it as a best-effort bonus, not a reliable refresh (see #27, #31).

## Alerts

Off by default. Turn them on in **Settings → Alerts** (Mac) or the bell button on the Trends screen (iOS); the first time asks for notification permission. Lows (urgent low and low) are on once alerts are enabled; highs are opt-in per level.

- An alert fires when a fresh Reading enters an enabled Band, and again when it moves from low to urgent low (or high to urgent high).
- While glucose stays out of range it repeats every 20 min for lows and 60 min for highs (adjustable). Coming back into range resets it and withdraws the delivered notification.
- No alert on a stale Reading or during sensor warm-up; a gap in data neither alerts nor counts as back in range.
- **Early warnings** use the forecast (so they need Therapy Settings): *heading low* fires when it predicts crossing the low threshold within 30 minutes (on once alerts are enabled), *heading high* within 60 minutes (off by default); both lead times are adjustable from 10 to 120 minutes. They debounce, repeat and snooze like the threshold alerts, in their own families, and stay quiet while glucose is already low (or high). Once warned, a warning stays on while the predicted crossing is within twice the lead time, so a crossing hovering at the edge does not re-alert every poll.
- **Falling fast** (on once alerts are enabled): when the CGM trend is falling and the forecast, which follows that trend for its first half hour, goes under 4.5 mmol/L within 20 minutes, it notifies "Falling fast: projected under 4.5 within 20 min". Threshold (3.9–7.0) and window (10–45 min) are adjustable. Its own family (`forecast.fallingFast`), repeating at the low repeat interval, time-sensitive on iOS, and silenced by Snooze.
- **Snooze for 1 hour** silences everything until it expires.

Alerts are evaluated after each poll, so they are only as timely as polling: on iOS that means while the app is open plus the best-effort background refresh, which iOS may delay or skip for hours. Keep the Libre app's own alarms on. Alert settings live in the shared App Group settings (so they follow you across Mac and phone once the App Group is granted); each app keeps its own record of what it has already alerted on.

On iOS, lows, heading-low warnings and urgent levels use the time-sensitive interruption level so they can break through a Focus. That needs the **Time Sensitive Notifications** capability on the app's identifier: with Automatic signing, add it under Signing & Capabilities (the entitlement is already in `SugarbarIOS.entitlements`). The Mac app posts at the default level; its ad-hoc-signed build can't carry that restricted entitlement.

## Learned Therapy Settings

`estimateTherapy` in `SugarbarCore/TherapyEstimator.swift` reads the last 28 days of History and logged Meals and looks for clean **Episodes**, using the same insulin action curve and carb model as the Forecast:

- **Correction Episode**: a Bolus (or Boluses within 45 minutes) with no Meal, starting at or above the high threshold. Gives sensitivity directly: glucose drop ÷ insulin that acted.
- **Meal Episode**: logged Meal(s) with their Bolus within 45 minutes. With a sensitivity, glucose change = carbs × sensitivity ÷ ratio − acted insulin × sensitivity gives the carb ratio.
- The window runs from the first event until the carbs are absorbed and at most 15% of the Episode's insulin is still to act (at least 3 h, about 3.5 h with the default curve, at most 7 h). Insulin still on board at the end is accounted for by the curve, and the tail of earlier Boluses is subtracted. A Bolus that lands inside the window joins the Episode and extends it.
- Skipped: another Meal in the window, a Meal in the 3.5 h before (carbs on board), earlier insulin on board above half the Episode's dose, glucose gapped for over 30 minutes or missing at either end, a sensor LO/HI, glucose already moving faster than 2.4 mmol/L per hour in the 30 minutes before, a dip below the low threshold followed by a rise of over 1 mmol/L within an hour (a low treated with unlogged carbs), and a rise of over 1.5 mmol/L that no logged Meal explains (above the starting value for a correction, after the post-meal peak for a meal). Episodes ending in the last 12 hours wait, because pen Doses reach History late. Corrections under 1 u and meals under 10 g or 0.5 u are too small to measure.
- Each Episode gives one value; recent ones weigh more (half-life 7 days). Values more than 3 robust standard deviations (and over 30%) from the weighted median are left out, and the rest are combined as a weighted geometric mean. Each estimate carries the Episodes, the effective sample size, the middle half of the values and a relative standard error, plus a morning / midday / evening / night breakdown when a slot has at least 4 Episodes.
- **Meals alone cannot give a carb ratio.** Each Meal Episode is one equation with two unknowns (sensitivity and ratio), and Boluses are usually proportional to carbs, so the two cannot be separated. The carb ratio uses the learned sensitivity when it has enough evidence, else the working sensitivity, else none is shown and the screen says what is missing.
- A **Suggestion** needs at least 5 Episodes over 3 days, an effective sample size of 3 and a standard error under 12%, and must differ from the working value by more than 10% and by more than twice its standard error (or there is no working value yet). Carb ratio is rounded to 0.5 g, sensitivity to 0.1 mmol/L.

The apps re-estimate in the background at most every 6 hours (and on **Estimate Now** in Therapy Settings, and after a change). Accepting writes the Therapy Settings and appends to the **Change Log**, which also records changes typed by hand; dismissing hides that Suggestion until the estimate moves more than 10% away from the dismissed value. Both are stored with the settings (`therapy.learning` in the App Group). Time-of-day values are shown, not applied: the Forecast uses one sensitivity and one ratio.

## Forecast feedback

- **Forecast Log** (`SugarbarCore/ForecastLog.swift`): every Forecast a device computes is logged, at most one per 5 minutes, as one JSON line in month files (`forecasts-YYYY-MM.jsonl` in `ForecastLog/` next to `History/`): the starting Reading, the prediction every 5 minutes for the first hour plus 90 and 120 minutes, Insulin and Carbs on Board, the CGM trend and its unexplained part, the carb slow-down factor, the Meals (with absorption speed) and Boluses still acting, the Therapy Settings used and the low threshold. Months entirely older than 90 days are deleted. Per device and never synced.
- **Scoring** (`SugarbarCore/ForecastScoring.swift`, pure): each logged Forecast is matched to the Readings at +15, +30, +60 and +120 minutes (a Reading within 90 s, else a line between Readings at most 16 minutes apart; nothing across a gap or at LO/HI) for the mean absolute error and the bias (predicted − actual), overall and split by situation: within 4 h of a Meal by its absorption speed, within 4 h of a Bolus with no Meal near it, overnight (00–06), quiet. Heading-low and falling-fast warnings are re-derived from the logged points with the current alert settings: consecutive warning Forecasts within 15 minutes are one warning, which is right when glucose crosses the threshold within the lead time (+10 min) after it, and a crossing no warning came before while Forecasts were being made is a miss; the lead time is from the first warning to the crossing.
- **Learning** (`SugarbarCore/ForecastLearning.swift`): the Forecast is replayed every 10 minutes over the last 6 weeks of History (leaving out the last 12 hours, since pen Doses arrive late) with nearby values of one parameter at a time, the others at their current values, and scored at 30, 60 and 120 minutes. Insulin peak and duration are judged on the clean Correction Episodes the sensitivity learning finds (first 4 h), each meal speed's absorption time on Meals of that speed with no other Meal near them, the trend blend on all replayed Forecasts grouped by day, and the carb correction limits on Meals where the slow-down hit that limit. Candidates are at most 20% from the current value, on the setting's own step (5 min, 15 min, 0.05×) and valid together with the other settings. A **Suggestion** needs at least 8 corrections, 5 meals of that speed, 8 meals or 7 days, over at least 3 days, a recency-weighted (half-life 14 days) error at least 4% and 0.05 mmol/L lower, and a better result in at least 60% of those events. Because wrong insulin timing also skews how meals seem to absorb, while an insulin timing Suggestion is pending only the strongest one is offered and no absorption Suggestion. Accepting one goes into Therapy Settings and the Change Log like a carb ratio. Runs with the sensitivity learning, at most every 6 hours, in about a tenth of a second on 6 weeks of History.
- **Track record**: the details area on the Mac panel and the iPhone Trends screen shows the last 14 days from the device's own log once it has a day of scored Forecasts, and until then the replay with the current settings, saying which. Ask Claude's History Summary carries the same scorecard and any pending forecast Suggestions.
- **Therapy Settings** gained fast and slow carb absorption times (they used to be half and 1.5× the normal time, which is what older stored and synced settings still decode to) and, under **Forecast tuning**, the trend blend (how long the unexplained CGM trend steers the Forecast, default 30 min) and the slowest and fastest carb correction (0.25× and 2×).

## Ask Claude

Open it from **Ask Claude** on the iOS Trends screen or the Mac panel. It needs a Claude API key: on iOS the one from the Meals card, on the Mac **Settings → Claude API Key** (each app keeps its own key in its Keychain; `SUGARBAR_ANTHROPIC_API_KEY` overrides both).

- On the first question the app builds a History Summary (`historySummary` in `SugarbarCore/HistorySummary.swift`): the last 24 hours as 15-minute means with every Dose, Meal and low episode timestamped in local time, one line per day for the 14 days (Time in Range per Band, mean, min/max, lows, bolus times and totals, basal total, carbs and Meals), and a median-by-hour profile, plus the current Forecast (Insulin on Board, Carbs on Board, where glucose settles) when there is one, and the learned sensitivity and carb ratio with their evidence and the last few Therapy Setting changes, the Forecast's 14-day Track Record and any pending forecast Suggestions, the dose calculation and Dose Settings, open Meal Plans (marked as not eaten) and each Meal's fat and protein. Units and the time zone are stated. A 14-day summary is about 8 KB (roughly 3k tokens).
- The summary goes in the system prompt, marked for prompt caching, and stays fixed for the conversation; each follow-up resends the conversation so far, with Claude's previous replies passed back unchanged. **Start Over** drops the conversation and rebuilds the summary on the next question.
- The conversation lives in memory only. Nothing is stored off the device apart from the request to the Claude API.
- Pen Doses only appear after an NFC sync and Meals only if logged; the summary and the prompt say so, so Claude can flag missing data.

## Sync

Off until you configure it: **Settings → Sync** on the Mac, **Sync** at the bottom of the Trends screen on the iPhone. Enter the Sync Server's address and access token (kept in each app's own Keychain, never synced or logged), then **Save**; the toggle turns it off again, and **Sync Now** runs it at once. The status line shows when it last synced, how many local changes are waiting, and the last error. Without an address and token the apps make no sync requests at all. The server lives under `Server/` and its wire contract is in [#47](https://github.com/Hammerset/sugarbar/issues/47).

What is sent: Meals (with Meal Plans), Manual Doses, Readings, Glooko Doses, and the settings sections thresholds, Therapy Settings, Dose Settings, alert settings (including a Snooze) and the Change Log with dismissed Suggestions. Poll cadence, the selected LibreLinkUp connection, the disclaimer, sign-ins, API keys and each device's record of alerts already posted stay on the device.

- **Local first:** each device keeps its own stores and the UI never waits on the network. `SyncEngine` (`SugarbarCore/SyncEngine.swift`) finds local changes by comparing each record with a fingerprint of what this device last synced, so every write path is covered, and queues them in an outbox. A sync pushes the outbox with `POST /v1/sync` and pulls everything after its cursor in the same request, page by page until `hasMore` is false. A queued change leaves the outbox only once the server has answered the request that carried it; the outbox, cursor and index are one file (`Application Support/Sugarbar/Sync/state.json`, per app) written atomically, so an app killed mid-sync resends rather than loses, and the server ignores a change it already has.
- **Conflicts:** latest `updatedAt` wins per record, on the server and on each device. Every local create, edit and delete is stamped with the time it was found (and always later than the version it replaces). The index keeps each record's last `updatedAt`, so a late older change never overwrites a newer one; a deleted Meal or Manual Dose stays in the index as a tombstone, never shown, so a stale local copy is removed rather than uploaded again.
- **First sync:** Meals and Manual Doses already on the device go up stamped with their own time, so a deletion made elsewhere since still wins. Settings never go up as a fresh install's defaults: on a device's first contact the server's copy wins when it has one; local settings are uploaded only when the server has none and they differ from the defaults, or when the user changes them afterwards.
- **Readings and Glooko Doses** use `/v1/readings` and `/v1/doses`. Readings go up per month in time order, in batches of 5,000, and the engine remembers how far each month got, so a sync sends only new Readings and a broken first upload resumes where it stopped. A month that gains older Readings (a late Backfill) is sent again whole, and the server ignores what it already has. Glooko Doses go up per month whenever the month changes. Downloads cover the last 90 days on the first sync, then what came since with a 3-hour overlap (3 days once a day), going through the History's own de-duplication. Data older than that overlap (a device's first upload, a late Backfill) would otherwise never reach the other devices, so the uploading device also leaves a `historyUpload` record per month with the time range it sent, and the others download that range.
- **When:** a few seconds after a local change, after a successful poll at most every 5 minutes, on launch, foreground and wake, and on **Sync Now**. Failures back off from 30 s to 30 minutes.
- **Apple Health:** only the iPhone writes Health. A Meal, edit or delete that arrives through sync is first put on a pending list, then its Health samples are deleted and written again by Meal id, so a Meal is in Health once even if it arrives twice or the app is killed halfway. The Mac never writes Health.

## Test

```sh
swift test
```

## Project layout

| Path | What |
|---|---|
| `project.yml` | XcodeGen spec for the Xcode project — the macOS app, iOS app, and widget extension targets. The `.xcodeproj` is generated from this, not committed. |
| `Package.swift` | SwiftPM package exposing the `SugarbarCore`/`SugarbarUI` libraries consumed by both app targets. Source of truth for the core; `swift test` runs against it. |
| `Sources/SugarbarCore/` | Source-agnostic domain + the LibreLinkUp client (auth, region redirect, fetch, polling, staleness), the Glooko client (web sign-in, CGM + dose fetch, backfill), the file-backed history store, the sync engine and its client, the Claude client shared by the meal analyzer (one Messages API call, lenient JSON parsing) and Ask Claude (History Summary + multi-turn conversation). No AppKit/UIKit. |
| `Sources/SugarbarUI/` | Shared SwiftUI presentation (band colours, `BarContent` text/glyph/tint, the history chart, alert settings rows, dose and meal entry fields, the Ask Claude chat) and notification delivery for alerts, consumed by both app targets. |
| `Sources/Sugarbar/` | The macOS app: menu-bar item, SwiftUI panel, settings, Log Meal window (file, drag and drop, paste, Continuity Camera), view model, app lifecycle. Built by the `Sugarbar` Xcode target. |
| `Sources/SugarbarIOS/` | The iOS app: sign-in, foreground polling, best-effort `BGAppRefreshTask` background top-up, current-reading screen, meal logging (camera/library photo and/or description, Claude estimate, review, edit/delete, HealthKit write), App Group snapshot + WidgetKit reload. Built by the `SugarbarIOS` Xcode target. |
| `Sources/SugarbarWidget/` | The WidgetKit extension: Home Screen (`systemSmall`/`systemMedium`, full colour) and Lock Screen (`accessoryCircular`/`accessoryRectangular`/`accessoryInline`, band conveyed by gauge fill/shape) glucose widgets. Reads the App Group snapshot only — no networking. Built by the `SugarbarWidget` Xcode target, embedded in `SugarbarIOS`. |
| `Tests/SugarbarCoreTests/` | Unit tests for the core, against recorded API responses. |
| `Server/` | The self-hosted sync server (its own Swift package, Hummingbird + Postgres, shipped as a container). How to run, back up and deploy it: [Server/README.md](Server/README.md). |
| `packaging/` | `package.sh` (build the macOS `.app`), `Info.plist`/`Sugarbar.entitlements` (macOS), `SugarbarIOS-Info.plist`/`SugarbarIOS.entitlements` (iOS) and `SugarbarWidget-Info.plist`/`SugarbarWidget.entitlements` (widget extension, both App Group), and `icon/` — the CoreGraphics source that renders `AppIcon.icns`. |

## Notes

- **Units:** the API returns mg/dL; the app converts to mmol/L (one decimal).
- **App icon:** generated from Swift/CoreGraphics in `packaging/icon/`. Regenerate the macOS `.icns` and the iOS `AppIcon` set (light, dark, tinted) with `packaging/icon/build-icons.sh`.
- **Build artifacts:** `Sugarbar.xcodeproj` is generated by `xcodegen` (git-ignored — regenerate with `xcodegen generate`); `swift build`/`xcodebuild` write to `.build/`, `package.sh` to `dist/` (all git-ignored).
- **App Group & signing:** the macOS app, the iOS app, and the widget extension all declare the `group.com.sugarbar` App Group so they can share the latest snapshot and settings. The macOS app's `package.sh` ad-hoc-signs, which embeds the entitlement but the OS won't *grant* the shared container until the app is signed with a real team — add a (free) Apple ID team in Xcode and switch the target to automatic signing when the macOS side needs it too ([#3](https://github.com/Hammerset/sugarbar/issues/3)). The iOS and widget targets already use Automatic signing; they just need a paid team selected in Signing & Capabilities to install on a device without the 7-day free-provisioning expiry.
- **Credentials are per-app:** each app target keeps its own LibreLinkUp Keychain entry (Phase 1, [#23](https://github.com/Hammerset/sugarbar/issues/23)) — signing in on the Mac app doesn't sign in the iOS app, and vice versa. Settings (thresholds, poll cadence, selected connection) and the latest snapshot *are* shared via the App Group.
- **API churn:** this rides an undocumented API. If Abbott bumps the LibreLinkUp app version, calls may start failing (`430`) until the `version` header in `LibreLinkUpClient` is updated. Likewise `GlookoClient` scrapes the Glooko web app's sign-in form and calls its dashboard JSON endpoint; a Glooko web redesign can break it.
- **Meals:** stored as JSON in the App Group (`shared.meals`) — that is what the graph reads on both platforms. `MealStore.upsert`/`delete` edit it by Meal id. Photos are downscaled to 1280 px on the long edge and re-encoded as JPEG before upload (`mealPhotoJPEG` in `SugarbarCore/MealPhoto.swift`, ImageIO, shared by both apps) and are never stored. The draft, review fields and recent-meal rows are shared SwiftUI in `SugarbarUI/MealEntryFields.swift`. A Meal carries an optional `plan` and a `state` (`planned` or `eaten`; Meals stored before planning decode as eaten), and everything that counts Meals (graph, totals, Forecast, learned settings, History Summary as eaten, Apple Health) skips planned ones. On iOS each eaten meal is also written to Apple Health as `dietaryCarbohydrates`, plus `dietaryFatTotal`, `dietaryProtein` and `dietaryEnergyConsumed` when known, each sample tagged with the Meal id (`HKMetadataKeyExternalUUID`), which is how an edit replaces them and a delete removes them; HealthKit only lets the app delete samples it wrote itself. Glooko does not import carbs from Health, so meals never reach Glooko.
- **History:** month files under `History/` — `readings-YYYY-MM.tsv` (one `epoch<TAB>mmol/L<TAB>trend` line per reading) and `doses-YYYY-MM.jsonl` — appended to on each poll and read a month at a time, never pruned. On iOS they live in the App Group container; the Mac app uses `~/Library/Application Support/Sugarbar/History` because its ad-hoc signature doesn't get the group container. History is not cleared by signing out; with [Sync](#sync) on, Readings and Glooko Doses are uploaded and downloaded.
- **Glooko backfill:** `GET /api/v3/graph/data` with series `cgmLow`/`cgmNormal`/`cgmHigh` returns 5-minute CGM points whose `value` is mg/dL × 100 (`100` and `200100` are the sensor's LO/HI clamps), with no trend; points flagged `calculated` are skipped. The first sync asks for 90 days in 7-day requests; later syncs resume an hour before the newest Glooko reading seen (a cursor file next to the history), always covering the last 24 hours for late pen syncs. Glooko's CGM data trails the sensor by a few hours.
- **Long ranges:** past 24 hours dose and meal markers are pooled (per 6 h for 3d, per day up to 30d, per week for 90d) and lose their inline labels — hover for totals. Past 7 days the line becomes a low–high band with its mean.
- **Forecast:** `forecast(readings:doses:meals:therapy:thresholds:sensorActivation:now:)` in `SugarbarCore/Forecast.swift`. Insulin follows Loop's exponential model (default peak 75 min, duration 6 h), each meal absorbs linearly over its speed's absorption time (defaults 1.5 h fast, 3 h normal, 4.5 h slow/fatty) at sensitivity ÷ carb ratio mmol/L per gram. The CGM trend is a least-squares slope over the last 15 minutes of 1- or 5-minute Readings, or over the last 20 minutes when only LibreLinkUp's 15-minute graph points and the live Reading are there, or else the live Trend arrow. Momentum adds the part of that trend insulin and carbs do not explain, fading from full weight to nothing over the trend blend (default 30 minutes), so the line starts at the CGM's rate and hands over to the model without double-counting the modelled effects or biasing the settled value. Retrospective correction compares the last 30 minutes' actual change with the model's: while carbs are absorbing, a miss beyond 0.3 mmol/L slows (falling faster) or speeds up (rising faster) the remaining carbs by a factor between the carb correction limits (default 0.25 and 2) that eases back to 1 over the next hour, which shifts carbs later without changing how much they raise glucose. Each point carries an uncertainty range (`lower`/`upper`): ±0.25 mmol/L plus 0.01 per minute ahead, plus half the trend–model disagreement per minute for up to an hour; `isUncertain` is set when that disagreement exceeds 0.06 mmol/L per minute. Points run every 5 minutes until the last dose or meal has finished acting (at least 3 hours, `forecastDisplayHorizon`, which is also what a chart shows), so `eventual` is the settled value. Basal is ignored. Therapy settings are stored with the other settings in the App Group. The apps recompute it after each poll, Glooko sync, logged meal and manual dose (`forecastFromHistory`), and `forecastAlertConditions` in `Alerts.swift` turns its crossings and the falling-fast projection into early-warning alerts (`forecast.low`/`forecast.high`/`forecast.fallingFast`). Dose and meal labels on the chart that would overlap are merged into one ("2 + 3.5").
- **Manual doses:** stored in the same `doses-YYYY-MM.jsonl` files with `"origin":"manual"` and an `entryId` (older lines without `origin` are Glooko doses). Edits append a new copy; deletes append a `{"deletedDoseId":…}` tombstone line, so the files stay append-only. `HistoryStore.doses(in:)` reconciles on read (`reconcileDoses` in `InsulinDose.swift`): a Glooko dose of the same kind and units within ±20 minutes supersedes one manual dose, closest in time first; with different units both are kept. Nothing is written back, so a superseded manual dose stays in the file but is never shown or counted.
- **Suggested Dose and strategy:** `suggestDose` in `SugarbarCore/SuggestedDose.swift` is pure and returns the parts or the reasons it is withheld; Insulin on Board comes from the current Forecast. `MealStrategist` (`SugarbarCore/MealStrategy.swift`) sends one request to Opus 5.5 with the meal, the Estimate, the calculation, current glucose and Trend, the Forecast and a 3-day History Summary, and parses a JSON strategy leniently, falling back to plain text. Claude's amounts are checked in code: a different amount without a reason is dropped, and one that is negative, off the pen step, above the maximum single dose or more than 20% (or one pen step) above the app's calculation is discarded with a caution; with no calculated dose no Claude amount is shown. Insulin on Board only counts Doses in sugarbar, so the card always says so with a button to log an earlier Dose, highlighted when the newest Glooko pen Dose is over 6 hours old and none was entered since (`doseCoverage`); the strategy prompt carries the same fact. Dose Settings are stored as JSON under `dosing.settings` in the App Group. The plan screens are shared SwiftUI in `SugarbarUI/MealPlanSections.swift`.
- **Stacking Warning:** `stackingWarning` in `SugarbarCore/BolusStacking.swift` is pure: Insulin on Board at the Dose's time from the reconciled Boluses with the same `ExponentialInsulinModel` as the Forecast, the previous Bolus, the remaining insulin effect (Insulin on Board × sensitivity) with and without the new Dose, the remaining carb effect of eaten Meals (`Meal.carbsAbsorbed`, the same linear per-Meal absorption the Forecast uses, without its retrospective slow-down), and whether current glucose − insulin + carbs would end below the low threshold. `stackingWarningFromHistory` reads the Doses from History; `StackingWarningView` in `SugarbarUI` shows it in the Mac panel, the Mac meal window's Dose entry and the iOS Dose sheet (which a meal plan's Log dose also opens). The two limits are `stackingInsulinOnBoard` and `stackingInterval` in Dose Settings; older stored settings without them decode to the defaults.
- **Dose timing:** Glooko only learns about a pen dose when the pen is synced to the Glooko app over NFC, so doses show up with that delay. Glooko is polled every 5 minutes, not on the sensor cadence.
