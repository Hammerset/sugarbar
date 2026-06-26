# Data source: LibreLinkUp unofficial API, behind a GlucoseSource abstraction

## Status

accepted

## Context

The Libre 3 Bluetooth stream is encrypted (AES + an NFC key exchange), so reading the sensor directly on macOS is not realistically feasible. Glucose data must therefore come through Abbott's cloud. The two viable cloud sources are the unofficial LibreLinkUp REST API (read the user's own Follower stream) and a self-hosted Nightscout server fed by a bridge.

## Decision

v1 reads from the **unofficial LibreLinkUp API** (`api-eu.libreview.io` for Norway), authenticating with the user's existing LibreLinkUp credentials. All data access sits behind a `GlucoseSource` protocol (`latest()` + `history(hours:)`) so the UI, colour logic, and graph never know which source produced a Reading.

Having a LibreLinkUp account that already receives a share from the Primary is a documented **prerequisite**, not something the app sets up.

## Considered Options

- **LibreLinkUp direct** (chosen) — zero extra infrastructure; one `/graph` call returns the latest value, the trend, and ~12h of history. Downsides: violates Abbott's ToS, breaks when Abbott changes auth (version header, SHA256 `account-id`), returns mg/dL only.
- **Nightscout intermediary** — robust, normalized, App-Store-survivable, but requires hosting a server and running a bridge 24/7. Rejected for v1 as too much plumbing before the app is useful.
- **Both up front** — doubles integration work before first value; deferred.

## Consequences

- The App Store goal is explicitly **out of scope for v1**: an app hitting Abbott's unofficial API and using the "Libre" name would almost certainly be rejected. The App-Store path is a future `NightscoutSource` (or Dexcom) behind the same `GlucoseSource` protocol — a swap, not a rewrite.
- The app must treat LibreLinkUp as unstable: keep the client version header current, tolerate missing/changed fields, and back off on `429`/`430`.
- This is informational software, not a medical device — see the disclaimer decision (separate).
