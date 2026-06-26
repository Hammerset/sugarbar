# sugarbar — implementation plan

A native macOS menu-bar app that shows the user's FreeStyle Libre 3 glucose: latest value + trend, colour-coded against a 5-band reference scale, with a 4-hour history graph in a click-through panel.

See `CONTEXT.md` for domain language and `docs/adr/` for decisions.

## Locked decisions

| Area | Decision |
|---|---|
| Data source | LibreLinkUp unofficial API (`api-eu.libreview.io`), behind a `GlucoseSource` protocol. LibreLinkUp account is a prerequisite. (ADR-0001) |
| Bar rendering | AppKit `NSStatusItem` — colored number + colored trend arrow, no unit label. (ADR-0002) |
| Units | mmol/L, one decimal. API gives mg/dL; convert with `/ 18.0182`. |
| Colour | 5 bands: urgent-low / low / in-range / high / urgent-high at **3.0 / 3.9 / 10.0 / 13.9 mmol/L**. Overridable in settings later. |
| Panel | SwiftUI popover: big value + arrow, age, sensor state, Swift Charts line graph with green band + threshold lines, 4h/8h/12h toggle (default 4h), Settings + Quit. |
| Polling | Aligned to the sensor clock (poll just after the next minute-value is due), jittered exponential backoff on `429`/`430`, pause on system sleep. |
| Stale/no-data | Calm-but-unmistakable: at >5 min gray the number + drop the arrow; icon when no value; detail in panel. **A stale reading is never shown in its in-range green.** |
| Auth | Email + password in Keychain, cached JWT, silent auto-refresh. Detect terms-update (`status:4`) and prompt to re-accept in the official app. |
| Disclaimer | First-run acknowledgement + persistent footer line. Not a medical device. |
| Platform | macOS 15 (Sequoia) deployment target. Agent app (`LSUIElement`), launch-at-login via `SMAppService` (toggle, offered at first run). |
| App Store | Out of scope for v1. Future path = a `NightscoutSource` behind the same protocol. (ADR-0001) |

## Architecture

```
NSStatusItem (label: NSHostingView<BarLabel>)  ──┐
NSPopover (SwiftUI panel + Swift Charts)         ─┤── ViewModel (@Observable)
                                                  │      ▲
PollingEngine (aligned clock + backoff)  ─────────┘      │ Reading / SensorState
                                                         │
GlucoseSource (protocol)  ◀── LibreLinkUpSource ◀── LibreLinkUpClient (auth, region, fetch)
                                                         │
                                              KeychainStore (email, password, jwt)
```

- **Domain types** (`Reading`, `Trend`, `Band`, `SensorState`) are source-agnostic — derived from mg/dL + thresholds, never from the API's own colour field.
- **`GlucoseSource`**: `func latest() async throws -> Reading`, `func history(hours:) async throws -> [Reading]`, `var sensorState: SensorState`.
- **`LibreLinkUpClient`** owns the unofficial-API mechanics; `LibreLinkUpSource` adapts it to `GlucoseSource`.

## LibreLinkUp mechanics (from verified research — build defensively)

- **Login**: `POST /llu/auth/login` `{email, password}`. Headers: `product: llu.android`, `version: <current LLU app version>`, `Content-Type: application/json`, a UA. On `{status:0, data:{redirect:true, region}}` retry against `api-<region>.libreview.io` (Norway → `eu`, possibly `eu2`). On success: `data.authTicket.token` (JWT ~180d), `data.user.id`.
- **`account-id` header** (mandatory since LLU 4.11): lowercase hex `SHA256(user.id)` on every authenticated call, plus `Authorization: Bearer <jwt>`.
- **`status:4`** = terms/privacy not accepted → surface a clear "open the official LibreLinkUp app and re-accept" message; no clean API-only path.
- **Data**: `GET /llu/connections` → pick the connection (auto-select the sole one; let user choose in settings if >1). `GET /llu/connections/{patientId}/graph` returns `connection.glucoseMeasurement` (latest, mg/dL in `ValueInMgPerDl`) **and** `graphData` (~12h history) — covers 4/8/12h in one call.
- **Trend enum**: `0 NotDetermined, 1 FallingQuickly, 2 Falling, 3 Stable, 4 Rising, 5 RisingQuickly`. Treat unknown as NotDetermined (no arrow).
- **Defensive posture**: keep the `version` header current; tolerate missing/renamed fields; back off on `429`/`430` (`430` is usually a header/version rejection, not pure rate-limit).

## Phased plan (tracer bullets — each phase ends in something you can see)

**Phase 0 — Skeleton in the bar.** Xcode SwiftUI app, `LSUIElement`, `NSStatusItem` showing a hardcoded `5.3 ↗` in green via `NSHostingView`. Clicking opens an empty `NSPopover`. _Done when: a colored number sits in your menu bar and a panel opens._

**Phase 1 — Real number, end to end.** `LibreLinkUpClient` (login → region redirect → `account-id` → connections → graph), `KeychainStore`, a temporary hardcoded-credential path. Map latest `ValueInMgPerDl` → mmol/L → `Reading`. _Done when: your actual current glucose shows in the bar (one manual fetch)._

**Phase 2 — Make it read right.** `Band` + threshold logic (5-band colour), `Trend` → SF Symbol arrow, mmol/L formatting (1 decimal). Tint number + arrow, tuned for light/dark bars. _Done when: the number is correctly colored and the arrow matches the official app._

**Phase 3 — Keep it fresh.** `PollingEngine`: aligned-to-clock scheduling, jittered backoff on `429`/`430`, pause/resume on sleep/wake. Staleness rule (>5 min → gray + drop arrow). _Done when: the bar updates itself every minute and visibly goes gray when data stalls._

**Phase 4 — The panel.** SwiftUI panel: big value + arrow + age + sensor-state line; Swift Charts 4h line with shaded green band + threshold lines; 4h/8h/12h toggle from the cached `graphData`. _Done when: clicking the bar shows your last 4 hours._

**Phase 5 — Make it yours.** Settings window: login (email/password → Keychain), connection picker (if >1), threshold overrides, poll interval, launch-at-login toggle (`SMAppService`). First-run disclaimer gate + persistent footer. _Done when: a fresh install can be set up with no code edits._

**Phase 6 — Sensor states & resilience.** Warm-up / signal-loss / sensor-error / sensor-ended / no-recent-data rendering (icons + panel copy), `LO`/`HI` out-of-range handling, token-expiry & terms-update recovery, network-loss handling. _Done when: every non-happy state degrades gracefully instead of showing a stale green number._

## Deferred / non-goals (v1)

- App Store distribution and the `NightscoutSource` (designed-for, not built).
- Local history beyond the API's ~12h window (24h+ ranges, time-in-range stats).
- Alerts/notifications on low/high (display-only for now).
- Multiple users beyond connection selection; watch/widget targets.

## Risks

- **API churn**: Abbott can change auth (version header, `account-id`) without notice — isolate it in `LibreLinkUpClient` and fail loudly with actionable messages.
- **Rate-limit bans**: temporary, IP-based; aligned polling + backoff keeps us well under the threshold.
- **Trend mismatch**: our arrow derives from the API enum; it may momentarily differ from the official app's. Acceptable for informational use.
- **Self-computed bands** must ignore the API's own colour/`isHigh`/`isLow` fields (undocumented) and derive from mg/dL + thresholds.
