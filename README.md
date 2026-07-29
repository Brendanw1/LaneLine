# LaneLine

Bike navigation for San Francisco, built around three ideas: routes weighted by
protected lanes and traffic stress, grade-aware planning that respects SF
hills, and Apple Music controls that live on the ride screen instead of
forcing an app switch at 18 km/h.

iOS 17+, SwiftUI-first, MusicKit-only music integration.

## Getting started

The Xcode project is generated — `LaneLine.xcodeproj` is not checked in.

```sh
brew install xcodegen          # once
xcodegen generate              # produces LaneLine.xcodeproj from project.yml
open LaneLine.xcodeproj
```

Run the `LaneLine` scheme on an iOS 17+ simulator or device. Tests:

```sh
xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Demo ride

DEBUG builds accept a launch argument that drops straight into an active
ride over the sample network with mocked location and music — handy for
ride-screen iteration and screenshots:

```sh
xcrun simctl launch booted com.laneline.LaneLine -demoRide
```

### Run it on your phone

The project is preconfigured with automatic signing and a development team,
so deployment is: plug the phone in, pick it as the run destination in
Xcode, and hit Run. First install only:

1. On the phone, trust the developer profile under
   *Settings → General → VPN & Device Management*.
2. Grant location, motion, and media permissions when the app asks.
3. Voice guidance speaks over your music (it ducks, then restores); the
   ride screen keeps the display awake while navigating.

Routing works city-wide immediately — the full SF street network and bikeway
data are bundled in `Resources/` (a filtered OpenStreetMap extract plus SFMTA
CSVs, see `NOTICE.md` for provenance), built into a graph on first launch
(~8s one-time cost, then disk-cached). Elevation for anything outside the
bundled bikeway network is nil (flat-grade assumption) until you run
*Settings → Fetch live SF bike network*, which re-ingests from live
DataSF/OSM sources with full elevation lookups (batched 100/request,
disk-cached) — a city-wide build takes minutes the first time and is instant
after.

### Apple Music on device

MusicKit needs the **MusicKit app service** enabled for the bundle ID
(`com.laneline.LaneLine`) in the Apple Developer portal under
*Certificates, Identifiers & Profiles → Identifiers → App Services*. There is
no entitlement file to manage. On simulator, authorization succeeds but
playback control requires a device signed into an Apple Music subscription;
the app degrades to a "connect" prompt state otherwise.

### DataSF app token (optional)

Live ingestion works anonymously against Socrata but is rate-limited. For
sustained use, put a token in `Support/Secrets.xcconfig` (gitignored) and pass
it through `DataSFBikewayClient.Configuration.appToken`.

## Architecture

```
App/            @main, root scene, AppModel (session state + persistence-through)
Core/           GeoMath, formatters, ServiceContainer (composition root)
Models/         Domain types: RiderProfile, RouteCandidate, RouteSegment, DTOs…
Services/
  GeospatialData/   Local bundled sources (default) + live DataSF/Overpass/USGS
                    clients, graph builder, sample loader
  Routing/          RouteGraph, A* planner, cost model, metrics, explanations
  AppleMusic/       MusicKit service (auth, subscription, playback, queue,
                    shuffle/repeat, playlists) + LRCLIB lyrics client
  Location/         CLLocationManager wrapper + mock
  RideRecording/    RideRecorder (1 Hz sampling), RideAggregator (pure metrics
                    math), CyclingPowerModel (calorie physics), RideStore
                    (JSON-per-ride persistence), AltimeterService (barometer)
  Persistence/      UserDefaults-backed store behind a protocol
Features/       One folder per screen flow (Onboarding, Search, RoutePlanning,
                RouteComparison, RouteDetail, Navigation, RideSummary,
                RideHistory, SavedPlaces, Settings)
DesignSystem/   Colors, typography, shared components, elevation chart,
                Liquid Glass adoption layer (iOS 26+, material fallback)
Resources/      Bundled SF street network + bikeway CSVs + elevation cache
                (see NOTICE.md for data provenance/licensing),
                SFSampleNetwork.json (fallback demo network)
Scripts/        generate_sample_network.py (provenance for the sample data)
Tests/          XCTest suite (76 tests)
```

Services are protocol-typed and injected through `ServiceContainer` in the
SwiftUI environment; previews and tests substitute mocks through the same
initializer, never through separate code paths.

### Data pipeline

Live ingestion and the bundled sample flow through the **same**
`NetworkGraphBuilder`; there is no separate demo code path.

1. **Bikeways** — DataSF Socrata dataset
   [`ygmz-vaxd`](https://data.sfgov.org/resource/ygmz-vaxd.json)
   ("MTA Bike Network Linear Features"). Facility classes map to the domain:
   CLASS I → off-street path, CLASS IV → protected lane, CLASS II →
   bike lane (buffered/raised variants), CLASS III → bike route/sharrows.
2. **Streets** — OpenStreetMap via the
   [Overpass API](https://overpass-api.de/api/interpreter): road class,
   surface, one-way rules, speed limits, cycleway tags.
3. **Elevation** — Open-Meteo's elevation API (Copernicus GLO-90 DEM,
   100 coordinates per request) as the batch-first primary, USGS EPQS
   (`epqs.nationalmap.gov`) as the point-query fallback; disk-cached per
   coordinate so re-ingestion is free.
4. **Fusion** — DataSF facility attributes are matched onto OSM geometry via
   a spatial midpoint index (25 m tolerance); unmatched edges keep OSM-derived
   attributes at reduced confidence. Polylines split into micro-edges between
   vertices, endpoints snap on a ~5.5 m grid, elevation attaches per node, and
   two-way streets expand into mirrored directed edges with negated grades.

Resolution order at runtime: in-memory graph → disk cache → bundled sample.
Settings shows the active source and offers "Fetch live SF bike network".

### Routing engine

A weighted directed graph (`RouteGraph`) searched with A*. Costs are
"equivalent seconds" so every penalty is explainable in time terms:

```
cost = time × facilityFactor × (1 + stressWeight × stress) × surfaceFactor
     + climb × climbSecondsPerMeter
     + steep-spike term + descent-caution term
     + confidence hedge
```

Weights resolve from bike type (road / hybrid / gravel / city / e-bike),
rider preferences (hill tolerance, safety, surface sensitivity), and strategy
(Recommended / Safer / Faster / Easier climbing). Road bikes strongly penalize
rough or unknown surfaces and grade spikes; e-bikes barely notice climbs.
Traffic stress follows an LTS-style model from road class, protection level,
posted speed, and lane count.

Candidates are deduplicated by edge overlap (Jaccard ≥ 0.9), capped at 1.7×
the shortest option, and limited to three. When every strategy converges on
one corridor, the planner penalizes the consensus edges and re-runs the
remaining strategies (penalty method) so riders still get a real alternative.
Every candidate carries a score breakdown, a plain-language recommendation,
and caution notes; the detail screen explains the hardest segment and how
preference changes would alter the pick.

### Apple Music

`AppleMusicService` is MusicKit-only by design: real authorization
(`MusicAuthorization.request`), subscription checks with live
`subscriptionUpdates`, `ApplicationMusicPlayer` state/queue observation via
Combine, play/pause/skip/seek, shuffle and repeat mode, queue reordering and
removal, ride playlist start, and library/catalog playlist resolution. The
ride screen hosts a compact bar; tapping it opens a full Now Playing sheet
with synced lyrics (via [LRCLIB](https://lrclib.net) — MusicKit exposes no
lyrics API at all), the editable queue, and system volume/AirPlay controls
(`MPVolumeView`/`AVRoutePickerView`). Its background is a gradient built
from `Artwork.backgroundColor`, Apple's own catalog-computed dominant color
for the current track. An upcoming turn still surfaces over the sheet via a
Dynamic-Island-styled banner, so navigation guidance is never fully hidden.

## Real vs. mocked

| Boundary | Status |
|---|---|
| DataSF / Overpass / USGS clients | Real HTTP clients against verified live endpoints |
| Bundled street/bikeway network | Real filtered OpenStreetMap (via BBBike) + SFMTA data, not synthetic — see `NOTICE.md`. Default routing source; live ingestion is opt-in ("Fetch live SF bike network") |
| Graph builder, A*, cost model, scoring | Real, fully tested |
| Bundled `SFSampleNetwork.json` | Curated demo data (44 nodes / 53 edges of real SF corridors: Valencia, the Wiggle, Market, Embarcadero…), generated by `Scripts/generate_sample_network.py`; only used if the bundled full-city sources ever fail to load |
| MusicKit integration | Real; `MockMusicService` exists for previews only |
| Lyrics | Real HTTP client against LRCLIB; best-effort, not every track matches |
| Location | Real `CLLocationManager`; `MockLocationService` (Valencia & 16th) for previews/simulator |
| Ride progress during navigation | Live GPS when on-route; sustained off-route drift freezes progress and auto-reroutes from the rider's real position; simulation only when there is no fix at all (simulator/demo) |
| Voice guidance | Real `AVSpeechSynthesizer` turn-by-turn prompts that duck music during announcements; mute toggle is functional |
| Persistence | Real UserDefaults-backed store |
| Ride statistics (speed, elevation, calories) | Real: GPS + barometer through `RideAggregator`; physics-based calorie model; demo mode feeds the same pipeline from the simulated position |
| Ride recording | Real file-backed `RideStore` (JSON per ride + summaries index in Application Support), 60 s crash checkpoints |

## License

Source code is MIT-licensed — see `LICENSE`. The bundled map, bikeway, and
elevation datasets in `Resources/` are third-party data under their own
terms (OpenStreetMap's ODbL among them) — see `NOTICE.md` before reusing or
redistributing this project.
