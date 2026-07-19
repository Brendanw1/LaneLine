# Ride Metrics Engine — Design

**Date:** 2026-07-19
**Status:** Approved
**Scope:** Phase 1 of the bike-computer feature set. Later phases (BLE sensors,
Apple Watch/HealthKit, temperature & wind, saved custom routes) build on the
interfaces defined here but are out of scope for this spec.

## Goal

Give LaneLine real, measured ride statistics during navigation — speed,
averages, elevation, grade, calories — displayed on customizable
bike-computer-style data pages, with completed rides recorded and browsable
in a history list.

## Decisions made during brainstorming

- **Build order:** metrics engine first; BLE sensors, watch, weather, and
  saved routes come in later phases.
- **Recording:** rides are sampled and persisted with a history list, not
  live-display-only.
- **Free-ride mode:** deferred. Recording happens only during navigation
  rides; the recorder is a standalone component so free-ride is a small later
  addition.
- **Stats UI:** the ride screen becomes a horizontal pager. The navigation
  page stays dominant and default with its compact metric strip; full-screen
  data pages sit beside it.
- **Customization:** data pages are user-customizable now (metric picker per
  cell), not fixed layouts.
- **Architecture:** standalone `RideRecorder` service, not an extension of
  `ActiveRideModel`.

## Components

### RideRecorder (`Services/RideRecording/`)

`@MainActor @Observable final class RideRecorder`, protocol-typed
(`RideRecording`) and registered in `ServiceContainer` like every other
service. `AppModel`'s ride lifecycle (`startRide`/`endRide`) starts and stops
it.

- **Inputs:** location fixes observed from `LocationServicing`; pause/resume
  from the ride screen; the active `RouteCandidate` (for start elevation,
  segment grades, and demo fallback).
- **Owns:** the growing sample log (`[RideSample]`, 1 Hz) and running
  aggregates (distance, elapsed, moving time, avg/max speed, ascent, descent,
  calories).
- **No-fix fallback:** when there is no GPS fix at all (simulator, demo
  ride), the recorder samples the simulated position/speed that
  `ActiveRideModel` already produces, so demo mode shows live stats through
  the same code path.
- `ActiveRideModel` is untouched except for surfacing measured speed instead
  of modeled speed on the ride screen.

### Measurement rules

Bike-computer conventions throughout:

- **Speed:** `CLLocation.speed` when valid (`≥ 0`) and fresh; otherwise
  derived from position deltas. Smoothed with a ~3 s exponential moving
  average. `CyclingSpeedModel` (modeled speed) remains for route planning and
  ETA only.
- **Elevation:** `CMAltimeter` barometric relative altitude, anchored to the
  route's known start elevation; GPS altitude (smoothed) as fallback when the
  barometer is unavailable. Ascent and descent accumulate with **2 m
  hysteresis** — small oscillations do not count as climbing.
- **Live grade:** smoothed elevation delta over the last ~20 m of travel;
  falls back to the current route segment's stored grade when elevation data
  is too noisy or missing.
- **Moving time / auto-pause:** speed below 1.0 m/s sustained for 3 s stops
  the moving clock; it restarts on movement. Average speed = distance ÷
  moving time. Elapsed time is tracked and shown separately.
- **Calories:** physics-based power estimate — rolling resistance + aero drag
  + climbing power computed from current speed, grade, rider weight, and a
  per-`BikeType` bike weight and drag profile — integrated over moving time
  and converted to kcal at ~24 % metabolic efficiency. `RiderProfile` gains
  `weightKg` (default 75, editable in Settings alongside the existing profile
  fields).
- **GPS gap handling:** a gap in fixes or a jump > 100 m between consecutive
  fixes accrues no distance; sampling resumes cleanly at the next good fix.

### Metric catalog

`RideMetricID` enum: `currentSpeed`, `averageSpeed`, `maxSpeed`, `distance`,
`distanceRemaining`, `elapsedTime`, `movingTime`, `eta`, `ascent`, `descent`,
`climbRemaining`, `grade`, `altitude`, `calories`, `clock`.

A catalog maps each ID to a display title, unit label, and formatted current
value (formatting via the existing `RideFormat`, extended with speed and
calorie formatters). Data-page cells render purely from metric IDs, so later
phases add power/HR/cadence/radar metrics as new IDs with no UI rework.

### Ride screen: pager + data pages

- Horizontal `TabView` (page style). **Page 0** is the existing navigation
  view, default and unchanged (compact strip, music tray, Liquid Glass).
  **Pages 1+** are full-screen data pages. Page dots indicate position.
- A data page is a 2-column × up-to-4-row grid of metric cells: large
  numerals, unit label, metric title, Liquid Glass card styling consistent
  with `DesignSystem`.
- **Edit mode:** entered from a pencil affordance on a data page; tapping a
  cell presents a metric picker sheet; pages can be added (up to 3) and
  removed. One sensible default page ships (speed, avg speed, distance,
  moving time, ascent, grade, calories, ETA).
- **Layout persistence:** `RideScreenCustomization` gains
  `dataPages: [RideDataPageLayout]` (each an ordered array of
  `RideMetricID`). Decoding is backwards-compatible: the new field defaults
  when absent so existing saved customizations do not reset.

### Persistence: RideStore (`Services/RideRecording/`)

`RideStoreProtocol` + `actor RideStore`, injected via `ServiceContainer`.
UserDefaults is wrong for growing sample logs, so rides live on disk:

- One JSON file per ride under
  `Application Support/Rides/<rideID>.json` (`RideRecord` = summary +
  samples).
- A lightweight `summaries.json` index for fast history listing.
- **Checkpoint:** the in-progress ride is written every 60 s so a crash or
  kill loses at most a minute.
- Store failures never block the ride: the recording stays in memory, a
  non-blocking alert surfaces, and saving retries at ride end.

Data model:

- `RideSample`: timestamp offset, lat, lon, altitude, speed, cumulative
  distance, grade.
- `RideSummary`: id, start date, route name/destination, duration, moving
  time, distance, avg speed, max speed, ascent, descent, calories.
- `RideRecord`: summary + samples.

### Ride completion & history

- On ride end (arrival or manual stop), a **ride summary screen** shows the
  stats grid, an elevation profile of the traveled track (reusing
  `ElevationProfileView`), and a map with the actual recorded polyline.
  Actions: save or discard.
- A **Rides** history surface joins the home screen next to Saved Places:
  rows show date, route name, distance, and time; tapping one reopens the
  summary screen from the stored record.

## Error handling

- Location gaps: covered by the gap rules above; the recorder never
  extrapolates distance.
- Barometer unavailable (older devices, denied motion permission): silent
  fallback to GPS altitude; ascent hysteresis compensates for the extra
  noise.
- Disk errors: ride kept in memory, non-blocking surface, retry on end.
- App relaunch mid-ride: out of scope (navigation itself does not survive
  relaunch today); the 60 s checkpoint means the partial ride still appears
  in history.

## Testing

- Aggregate math unit tests: ascent/descent hysteresis, auto-pause
  transitions, avg/max speed, gap handling, calorie model plausibility
  bounds (e.g., flat 20 km/h ride lands in a sane kcal/h band).
- `RideRecorder` end-to-end: scripted fix sequences through
  `MockLocationService`, asserting samples and aggregates.
- `RideStore`: round-trip save/load/list/delete, checkpoint overwrite.
- Existing 28-test suite must keep passing unmodified.

## Explicitly out of scope (deferred)

GPX/FIT export, imperial units, HealthKit/watch, BLE sensors, temperature &
wind, free-ride recording, saved custom routes. The metric catalog, recorder
protocol, and ride store are shaped so each is additive.
