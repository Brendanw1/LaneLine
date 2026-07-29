# Course-First Navigation Orientation — Design

**Date:** 2026-07-29
**Status:** Approved
**Scope:** Fix map/puck orientation during active bike navigation so it's
driven primarily by real travel direction (GPS course), not phone compass
heading. Camera follow-suspend/recenter on manual pan is in scope. Voice
guidance, route planning/comparison maps, and the route-overview sheet are
unaffected.

## Problem

`ActiveRideModel.refreshHeading()` is heading-first today:

```swift
let raw = locationService.currentHeading ?? routeBearingHeading
```

The phone's magnetometer compass is the primary source; route bearing is
only a fallback for when there's no compass reading at all. On a bike-mounted
phone the compass is the noisy signal (frame/mount metal, phone tilt, nearby
traffic), while GPS course (`CLLocation.course`) is the trustworthy one once
the rider is actually moving. The existing smoothing (shortest-angle delta +
exponential blend) is sound — the wrong signal is being fed into it.

## Decisions made during brainstorming

- **Architecture:** a new standalone, unit-testable engine
  (`NavigationOrientationEngine`), not more private methods on
  `ActiveRideModel`. Two alternatives considered and rejected:
  - Expanding `ActiveRideModel`'s existing private methods in place — fails
    the testability goal; exercising angle-fusion edge cases would require
    standing up a full `@MainActor` ride model with a route and routing
    service just to test angle math.
  - Pushing the fusion policy into `LocationService` — wrong layer.
    `LocationService` is raw sensor access; "trust course over heading while
    moving" is navigation policy, and baking it in there would make
    `LocationService` untestable without a real/mocked `CLLocationManager`
    and would leak domain logic into infrastructure.
- **Generic angle math** (normalize, shortest delta, interpolate) moves into
  `Core/GeoMath.swift`, alongside the `bearingDegrees` it already has, rather
  than staying as private statics on `ActiveRideModel`.
- **Puck rotation needs no new code.** The rider marker is a plain
  `Annotation` that intentionally does not self-rotate — the camera itself
  is heading-locked, so "up on screen" already equals "direction of travel."
  Fixing what feeds the camera's heading fixes the puck for free.
- **Camera update cadence** stays on the existing 1 Hz tick loop rather than
  gaining a second, independent timer — a separate cadence would decouple
  camera updates from the same loop that drives off-route detection and
  voice announcements, more moving parts than this warrants.
- **Follow-suspend/recenter is in scope for this round** (not deferred),
  per explicit confirmation — manual pan/rotate during navigation should
  suspend camera auto-follow with a recenter action, rather than the camera
  fighting the gesture every tick as it does today.
- **Voice guidance is untouched** — confirmed by reading `RideVoiceGuide`/
  `updateAnnouncements()`; neither has any coupling to heading or course.
- **No Info.plist or entitlement changes** — course, speed, and course
  accuracy ride on `CLLocation` for free under the location authorization
  the app already requests.

## Components

### `Core/GeoMath.swift` (existing file, extended)

Three pure, generic angle functions, moved out of `ActiveRideModel`'s
private statics so they're independently testable:

- `normalizedDegrees(_:) -> Double` — wraps into `0..<360`
- `shortestAngleDelta(from:to:) -> Double` — signed shortest angular
  distance, handling the 359°→1° wraparound
- `interpolatedAngle(from:to:fraction:) -> Double` — one exponential-smoothing
  step, factored out so smoothing itself is independently testable from the
  source-selection logic that decides what to interpolate toward

### `Features/Navigation/NavigationOrientationEngine.swift` (new)

Co-located with `ActiveRideModel`/`RideVoiceGuide`, matching how this feature
area is already organized.

**`NavigationOrientationConfig`** — tunable thresholds, all with defaults:

| Knob | Default | Purpose |
|---|---|---|
| `minimumSpeedForCourseMetersPerSecond` | 1.4 (~5 km/h) | below this, GPS course is not trusted as travel direction |
| `maximumHeadingAccuracyDegrees` | 35 | `CLHeading.headingAccuracy` above this is too noisy to use |
| `courseFreezeGraceSeconds` | 3 | how long to keep steering by the last good course after slowing, before falling back to heading |
| `smoothingFactor` | 0.35 | exponential blend factor toward each new raw bearing (matches today's existing constant) |
| `minimumAngleDeltaDegrees` | 1.5 | suppresses sub-noise-floor jitter from ever reaching the screen |

Course trust does **not** get its own configurable accuracy threshold beyond
basic validity (`course >= 0`) — only a heading-accuracy knob was asked for;
adding an unrequested course-accuracy tunable would be scope creep.

**`OrientationSource`** — `.course`, `.heading`, `.routeBearing`.

**Pure static filter functions** (no CLLocation dependency, plain numbers in/out):
- `isCourseTrustworthy(speedMetersPerSecond:course:config:) -> Bool`
- `isHeadingTrustworthy(heading:accuracy:config:) -> Bool`

**`NavigationOrientationEngine`** — the one stateful piece. Owns the
freeze-on-slowdown grace timer and the smoothed bearing.

```
update(location:, heading:, headingAccuracy:, routeBearing:, deltaSeconds:) -> Double
```

State machine:

```
speed >= threshold, course valid
    -> COURSE (remember it, reset grace timer to 0)
speed < threshold or course invalid
    -> if a good course was seen within courseFreezeGraceSeconds
           -> keep steering by that FROZEN course (accumulate grace timer)
       else if heading valid and heading accuracy <= config max
           -> HEADING
       else
           -> ROUTE BEARING (last resort; same fallback behavior as today)
resume: the instant course/speed are trustworthy again -> COURSE immediately,
        no grace period on the way back up
```

### `Features/Navigation/ActiveRideModel.swift` (modified)

`refreshHeading()` and its private angle statics are removed. A
`NavigationOrientationEngine` instance replaces them; `displayHeading`
becomes a computed property reading the engine's smoothed bearing, so
`ActiveNavigationView` needs no changes for the fusion logic itself.
`routeBearingHeading` is unchanged in implementation, only repositioned
semantically — it's now tier-3 fallback instead of tier-2.

### `Services/Location/LocationService.swift` (modified)

`LocationServicing` gains one new property: `currentHeadingAccuracy: Double?`
— the raw `CLHeading.headingAccuracy`, published alongside `currentHeading`
so the engine can apply its own configurable threshold rather than the
fixed valid/invalid check `LocationService` does today. Implemented on both
`LocationService` and `MockLocationService`.

`MockLocationService.setLocation(...)` gains optional `course`, `speed`, and
`courseAccuracy` parameters (default `nil`), used to construct a full
`CLLocation` via its extended initializer instead of the coordinate-only one.
Existing call sites in `RideRecorderTests.swift` are unaffected — all new
parameters default away.

### `Features/Navigation/ActiveNavigationView.swift` (modified)

`rideMap` gains `@State private var isFollowSuspended = false` and
`.onMapCameraChange(frequency: .continuous)`. When the reported camera
diverges (beyond a small position/heading epsilon) from the camera this view
last commanded itself, that's inferred as a user gesture and
`isFollowSuspended` is set. The existing `onChange(of: ride.progressMeters)`
block that overwrites `camera` is guarded by `!isFollowSuspended`. A floating
"Recenter" button (styled like the existing overview-map toggle) appears
while suspended; tapping it clears the flag and snaps `camera` back to
`followCamera(ride)`.

This heuristic isn't perfectly bulletproof — MapKit's continuous
camera-change callback fires for both programmatic and gesture-driven
changes — but comparing against the last self-commanded camera is the
standard technique for this and is good enough in practice; false positives
just mean an extra recenter tap.

## Error handling / edge cases

- **No location fix at all** (simulator, demo, tunnel): unchanged from
  today — falls through to route bearing, same as the existing no-fix path.
- **Stale fix:** out of scope for this pass — `LocationService` already only
  publishes a value when `CLLocationManager` delivers one; there's no
  separate staleness timeout being added, since the tick loop's 1 Hz cadence
  combined with route-bearing fallback on `nil` already covers the practical
  cases (tunnel, GPS drift) without new bookkeeping.
- **Sharp turns:** the jitter-suppression floor (`minimumAngleDeltaDegrees`)
  and the smoothing factor (`0.35`, unchanged from today) are tuned so a
  real turn still visibly rotates within a couple of ticks rather than
  lagging — validated by a dedicated test case, not just asserted.
- **Wraparound (359° -> 1°):** handled by `shortestAngleDelta`, unit tested
  directly.

## Testing

New `Tests/NavigationOrientationEngineTests.swift`:

- `GeoMath` cases: wraparound normalization, shortest-delta symmetry across
  the 0/360 boundary, interpolation at fraction 0 / 0.5 / 1.
- Filter-function cases: invalid course (`< 0`) rejected regardless of
  speed; speed below threshold rejected even with a perfect course; heading
  rejected when accuracy exceeds the configured max; heading rejected when
  `nil`.
- State-machine cases: moving with good course selects `.course`; slowing
  below threshold keeps the frozen course for `courseFreezeGraceSeconds`
  before falling back; resuming speed switches back to `.course`
  immediately with no grace delay; a real sharp turn still rotates promptly
  despite the jitter floor.

One `ActiveRideModel`-level integration test using the new
`MockLocationService` course/speed setter, driving a moving → stopped →
moving scenario and asserting `ride.displayHeading` tracks accordingly.

Existing test suite (81 tests as of the last shipped feature) must keep
passing unmodified.

## Explicitly out of scope (deferred)

Stale-fix timeout as an independent config knob, a UI indicator of which
orientation source is currently active (kept internal, no user-facing
change), pitch/zoom tuning changes (unrelated to this fix, left as-is), and
any change to the route-planning/comparison/overview maps (all north-up,
unaffected by this pass).
