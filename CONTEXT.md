# sugarbar

A macOS menu-bar app that displays the user's own FreeStyle Libre 3 glucose data — latest value, trend, colour-coded against a reference range, with a history graph reaching back up to 90 days.

## Language

**Reading**:
A single glucose measurement at a point in time, with a value, a timestamp, and a trend.
_Avoid_: sample, datapoint, measurement (reserve "measurement" for the raw API field).

**Trend**:
The direction and speed glucose is moving at the latest Reading — one of falling-quickly, falling, stable, rising, rising-quickly.
_Avoid_: arrow (that's the glyph), slope, delta.

**Reference Range**:
The glucose band considered in-range (the "green" zone). Consensus adult target is 3.9–10.0 mmol/L.
_Avoid_: target range, normal range, healthy range.

**In-Range / Low / High**:
A Reading's status relative to the Reference Range. Low is below it, High is above it; each has an urgent sub-level.
_Avoid_: hypo/hyper (clinical terms we don't surface), out-of-range.

**Band**:
The colour zone a Reading falls into — one of urgent-low, low, in-range, high, urgent-high — at cutoffs 3.0 / 3.9 / 10.0 / 13.9 mmol/L. Drives the colour of the number in the bar.
_Avoid_: zone, level, severity.

**Primary**:
The phone running the main FreeStyle Libre 3 app that owns the sensor and uploads readings.
_Avoid_: master, sensor app.

**Follower**:
A LibreLinkUp account that receives a share from a Primary. sugarbar reads the Follower stream, never the sensor directly.
_Avoid_: viewer, subscriber.

**Staleness**:
How old the latest Reading is. Beyond ~5 minutes with no new Reading, data is considered stale ("No Recent Data").
_Avoid_: lag, delay.

**Sensor State**:
A non-reading condition the app must show gracefully: warm-up (first 60 min), signal-loss, sensor-error, sensor-ended.
_Avoid_: status, error.

**Alert**:
A local notification that the latest live **Reading** is Low or High, raised when it enters an enabled **Band**, escalates to the urgent sub-level, or is still out of range after the repeat interval. Never raised on a **Stale** Reading or during a **Sensor State**. Opt-in, off by default.
_Avoid_: alarm (that's the Libre app's own feature, which sugarbar does not replace), warning.

**Snooze**:
A user-chosen window during which no **Alert** is posted. An alert suppressed by a Snooze is not counted as delivered, so it fires once the Snooze ends if still applicable.
_Avoid_: mute, silence.

**Dose**:
One insulin injection with a unit amount, a timestamp (when the pen fired, not when it synced), and a kind — **Bolus** (rapid-acting, mealtime/correction) or **Basal** (long-acting, background). Comes from Glooko, or is entered by hand in sugarbar (a **Manual Dose**), never the sensor.
_Avoid_: injection, shot, entry.

**Manual Dose**:
A Dose the user enters in sugarbar right after injecting, so the graph and Forecast have it before the Pen is synced. Editable and deletable, unlike a Glooko Dose. A Glooko Dose of the same kind and units within 20 minutes **supersedes** it: the Manual Dose is hidden and the Pen's timestamp wins.
_Avoid_: logged dose (Glooko also has typed-in Doses), pending dose.

**Pen**:
A connected insulin pen (NovoPen 6) whose memory is synced to the Glooko app over NFC. A **Dose** from a Pen carries the pen's name; a manually typed Dose carries none.
_Avoid_: device (too generic), smart pen.

**Meal**:
Carbohydrates eaten at a point in time, in grams, with a short description. Logged from a photo on the phone: Claude proposes an **Estimate**, the user confirms or edits the grams, and only the confirmed figure is saved.
_Avoid_: food log, entry, carbs (the number, not the event).

**Estimate**:
Claude's proposed carb figure for a Meal photo, with the foods it saw, what it assumed, and a confidence. Never saved as-is — a starting point for the review step.
_Avoid_: result, answer, prediction.

**History**:
The durable record of Readings and Doses kept on each device, never pruned. Fed by every successful poll and by **Backfill**; the graph and Time in Range read from it. Meals are not part of it — they already persist in the App Group.
_Avoid_: log, archive, cache, database.

**Backfill**:
Readings and Doses pulled from Glooko into History for times the app was not polling — the past 90 days on first sign-in, then whatever Glooko has gained since. Glooko only learns about Readings hours after the sensor, so LibreLinkUp stays the live source and Backfill fills the gaps.
_Avoid_: import, sync, catch-up.

**Range**:
The span of History the graph shows and Time in Range summarises — 4h, 12h, 24h, 3d, 7d, 14d, 30d or 90d (`HistoryWindow` in code).
_Avoid_: period, zoom.

**Time in Range**:
The share of a Range spent in each Band. Counted in five-minute slots, so a minute-by-minute live stretch weighs the same as a five-minute backfilled one, and time with no Readings counts for nothing.
_Avoid_: TIR in UI copy, score, compliance.

**Therapy Settings**:
The user's personal factors the Forecast needs: insulin sensitivity (mmol/L one unit of Bolus lowers glucose), carb ratio (grams one unit covers), and insulin duration, insulin peak and carb absorption time. Sensitivity and carb ratio have no defaults; the timings default to 6 h, 75 min and 3 h.
_Avoid_: profile, factors, ISF/ICR in UI text.

**Forecast**:
Where glucose is predicted to head, in 5-minute points from the latest Reading until every Dose and Meal has finished acting (at least 3 hours): the summed effect of Bolus insulin, Meal carbs and recent momentum (the part of the recent slope that insulin and carbs do not explain). Carries the eventual (settled) value and the first predicted crossing of the low and high thresholds. Says where glucose is heading, never how much insulin to take.
_Avoid_: prediction (fine in prose, not as a type), projection, dose advice.

**Insulin on Board**:
Bolus units still to act at a moment, from each Dose's exponential activity curve. Basal is not counted.
_Avoid_: IOB in UI text, active insulin.

**Carbs on Board**:
Grams of logged Meal carbs not yet absorbed at a moment, with each Meal absorbing evenly over the carb absorption time.
_Avoid_: COB in UI text, active carbs.

**History Summary**:
The compact text account of recent **History**, **Doses**, **Meals**, thresholds and **Therapy Settings** that Ask Claude sends to Claude: the last 24 hours at 15-minute resolution with every event, one line per day, and a median-by-hour profile, in mmol/L and local time. Built once per conversation.
_Avoid_: export, report, dump.

**Ask Claude**:
A chat with Claude about the user's own **History Summary**. Multi-turn within a session, held in memory only. Gives observations and things to discuss with a care team, never a dose for the future.
_Avoid_: assistant, coach, advice.

## Relationships

- A **Primary** shares to one or more **Followers**; sugarbar authenticates as a **Follower**.
- A **Reading** has exactly one **Trend** and one status (**In-Range** / **Low** / **High**) derived from the **Reference Range**. A backfilled Reading's Trend is always not-determined: Glooko does not carry one.
- **History** holds each **Reading** once: the same sensor Reading arriving from LibreLinkUp and from **Backfill** (timestamps within 30 s) is kept as the first copy seen. A Glooko **Dose** is identified by its kind and timestamp; a later copy (e.g. units edited in Glooko) replaces the earlier one. A **Manual Dose** has its own identity, so two entered in the same minute both stay, and an edit replaces it in place.
- A Glooko **Dose** supersedes at most one **Manual Dose** and vice versa, the closest in time first. If the units differ, both are kept. Everything that reads Doses (graph, totals, Forecast) sees them after superseding.
- A **Reading**'s **Staleness** is independent of its value — a fresh-looking number can still be stale.
- A **Sensor State** can exist with no current **Reading** (e.g. warm-up).
- An **Alert** belongs to a family (low, high; later e.g. predicted low). Each family debounces on its own: one alert on entering, one more on escalation, then one per repeat interval; leaving the family resets it.
- A **Dose** is independent of any **Reading**; the graph overlays Doses on Readings by time only.
- Doses are only as fresh as the last **Pen** sync — there is no Staleness notion for them.
- A **Meal** is independent of any **Reading** or **Dose**; the graph overlays all three by time only.
- A **Meal** always passes through an **Estimate** and a user review; the stored Meal is the user's figure, not Claude's.
- A **Forecast** needs complete **Therapy Settings** and a fresh **Reading**; there is none from a Stale Reading, a LO/HI Reading, or during a **Sensor State**.
- A **Forecast** counts only **Bolus** Doses; **Basal** is assumed to cover background needs. A Pen Dose not yet synced to Glooko is missing from it unless it was entered as a **Manual Dose**, so a Forecast right after an unsynced, unentered Bolus reads too high.
- An **Ask Claude** conversation is pinned to the **History Summary** built for its first question; Readings that arrive later are not in it until **Start Over**.
- Meals live in the App Group (phone, Mac panel, widget) and are mirrored to Apple Health. Nothing flows from Meals to Glooko.

## Example dialogue

> **Dev:** "When the sensor is warming up, what does the bar show?"
> **Domain expert:** "There's no **Reading** during warm-up, so you show the **Sensor State**, not a number — and definitely not a stale old value coloured as if it were live."
> **Dev:** "And if the last **Reading** is 8 minutes old but in range?"
> **Domain expert:** "It's **In-Range** by value, but it's **Stale** — surface the age, don't pretend it's live."

## Flagged ambiguities

- "the app" was ambiguous between the **Primary** FreeStyle Libre 3 app, the **LibreLinkUp** follower app, and sugarbar — resolved: name each explicitly.
