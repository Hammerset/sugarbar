# sugarbar

A macOS menu-bar app that displays the user's own FreeStyle Libre 3 glucose data — latest value, trend, colour-coded against a reference range, with a recent-history graph.

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

**Dose**:
One insulin injection with a unit amount, a timestamp (when the pen fired, not when it synced), and a kind — **Bolus** (rapid-acting, mealtime/correction) or **Basal** (long-acting, background). Comes from Glooko, never the sensor.
_Avoid_: injection, shot, entry.

**Pen**:
A connected insulin pen (NovoPen 6) whose memory is synced to the Glooko app over NFC. A **Dose** from a Pen carries the pen's name; a manually typed Dose carries none.
_Avoid_: device (too generic), smart pen.

**Meal**:
Carbohydrates eaten at a point in time, in grams, with a short description. Logged from a photo on the phone: Claude proposes an **Estimate**, the user confirms or edits the grams, and only the confirmed figure is saved.
_Avoid_: food log, entry, carbs (the number, not the event).

**Estimate**:
Claude's proposed carb figure for a Meal photo, with the foods it saw, what it assumed, and a confidence. Never saved as-is — a starting point for the review step.
_Avoid_: result, answer, prediction.

## Relationships

- A **Primary** shares to one or more **Followers**; sugarbar authenticates as a **Follower**.
- A **Reading** has exactly one **Trend** and one status (**In-Range** / **Low** / **High**) derived from the **Reference Range**.
- A **Reading**'s **Staleness** is independent of its value — a fresh-looking number can still be stale.
- A **Sensor State** can exist with no current **Reading** (e.g. warm-up).
- A **Dose** is independent of any **Reading**; the graph overlays Doses on Readings by time only.
- Doses are only as fresh as the last **Pen** sync — there is no Staleness notion for them.
- A **Meal** is independent of any **Reading** or **Dose**; the graph overlays all three by time only.
- A **Meal** always passes through an **Estimate** and a user review; the stored Meal is the user's figure, not Claude's.
- Meals live in the App Group (phone, Mac panel, widget) and are mirrored to Apple Health. Nothing flows from Meals to Glooko.

## Example dialogue

> **Dev:** "When the sensor is warming up, what does the bar show?"
> **Domain expert:** "There's no **Reading** during warm-up, so you show the **Sensor State**, not a number — and definitely not a stale old value coloured as if it were live."
> **Dev:** "And if the last **Reading** is 8 minutes old but in range?"
> **Domain expert:** "It's **In-Range** by value, but it's **Stale** — surface the age, don't pretend it's live."

## Flagged ambiguities

- "the app" was ambiguous between the **Primary** FreeStyle Libre 3 app, the **LibreLinkUp** follower app, and sugarbar — resolved: name each explicitly.
