# LaneLine — Product Requirements & Technical Specification

## PRD (Product Requirements Document)

### Product Summary
LaneLine is an iOS bike routing app for San Francisco that recommends better routes for cyclists, especially road-bike riders, by using bikeway data, street attributes, and hill-aware routing instead of simple shortest-path logic. The app also integrates Apple Music directly into the active ride screen using MusicKit so mounted-phone riders can control music without leaving navigation.

### User Problem
Existing navigation apps often choose routes that are technically valid but poor for an actual road-bike ride. They may underweight steep ramps, overuse stressful arterials, ignore surface quality, and fail to explain route tradeoffs. Riders also often need to switch apps to manage music while riding.

### Product Goals
- Recommend routes that are better for the actual rider and bike type.
- Make route tradeoffs understandable before a ride starts.
- Keep active navigation glanceable and safe for a mounted phone.
- Integrate Apple Music in a way that is useful but secondary to navigation.
- Build around real data structures and real integrations, not just mock UI.

### Non-Goals
- Full multi-city support in v1.
- Support for music providers other than Apple Music.
- Perfect production-grade turn-by-turn engine in the first pass.
- Social feed, ride tracking community features, or Strava-like competition features.

### Primary Personas
- Road-bike rider in San Francisco who wants smoother, safer, less punishing routes.
- Hybrid or fitness-bike commuter who wants protected lanes and lower stress.
- E-bike rider who still values safety but is less hill-sensitive.

### Primary User Stories
- As a rider, I want route options that reflect my bike type and hill tolerance.
- As a rider, I want to know why one route is recommended over another.
- As a rider, I want a ride screen that is readable at a glance on a mounted phone.
- As a rider, I want Apple Music controls on the same screen as navigation.
- As a rider, I want to tune the balance between safer routes, easier climbing, and directness.

### Core v1 Features
- Rider onboarding and profile setup
- Bike-type-aware route preferences
- Destination search and route generation
- 2–3 route options with explainable tradeoffs
- Route detail screen with route metrics and explanation
- Active navigation screen with compact and expandable Apple Music controls
- Ride screen customization
- Saved places and route presets

### Success Criteria
- Route comparison feels meaningfully different from generic map apps.
- Recommended routes clearly reflect bike type and user settings.
- Apple Music is genuinely integrated into navigation, not visually faked.
- Architecture is ready to connect real data ingestion and scoring.

---

## TECH SPEC

### Recommended Build Workflow
1. Build the SwiftUI app shell and navigation architecture.
2. Define route, segment, rider, settings, and Apple Music models.
3. Build the routing service interfaces around real geospatial ingestion assumptions.
4. Implement route scoring with mock SF sample routes that use the real model shape.
5. Implement MusicKit authorization and playback service boundaries.
6. Build route comparison and route detail views.
7. Build the active navigation screen with compact and expanded music controls.
8. Add persistence for rider settings, saved places, and screen customization.

### Suggested Repo Structure

```
LaneLine/
  App/
  Core/
  DesignSystem/
  Models/
  Features/
    Onboarding/
    Search/
    RoutePlanning/
    RouteComparison/
    RouteDetail/
    Navigation/
    Settings/
    SavedPlaces/
  Services/
    Routing/
    GeospatialData/
    Location/
    AppleMusic/
    Persistence/
  PreviewContent/
  Tests/
```

### Core Services
- **RoutingService**: generates route candidates from graph inputs and rider preferences.
- **GeospatialDataService**: ingests bikeway, OSM, and elevation-derived inputs.
- **RouteScoringService**: converts segment attributes into weighted route scores.
- **LocationService**: current location, heading, and navigation state.
- **AppleMusicService**: authorization, subscription status, now playing, playback control.
- **PersistenceService**: rider profile, saved places, UI preferences, route settings.

### Real Integration Expectations
- Real integrations should be explicit at the boundary layer even if demonstration data is mocked.
- SFMTA / DataSF bikeway network: represented as importable network and point feature inputs.
- OSM-derived street attributes: represented as normalized road and bike metadata.
- Elevation / slope: represented as segment-level grade and climb fields.
- Apple Music: represented through MusicKit authorization and playback-aware state.

### Mocking Rule
Mock data is allowed for previews and route demos, but only in these places:
- sample route candidates
- preview ride states
- preview Apple Music now-playing states
- temporary geospatial fixture data

Mock data must use the same models and service contracts as the intended real implementation.

---

## DATA MODEL

### Core Rider Models

```
RiderProfile
- id
- name
- bikeType
- hillTolerance
- safetyPreference
- directnessPreference
- surfaceSensitivity
- appleMusicEnabled
- defaultRidePlaylistID
```

```
BikeType
- roadBike
- hybridFitness
- gravel
- cityBike
- eBike
```

```
RoutePreferenceProfile
- protectedLanePriority
- climbingPenaltyWeight
- maxGradeAvoidance
- directnessWeight
- surfacePenaltyWeight
- dangerousIntersectionPenalty
- avoidUnpaved
- preferRecommendedBikeCorridors
```

### Routing Models

```
RouteSegment
- id
- geometry
- lengthMeters
- estimatedSeconds
- averageGrade
- maxGrade
- elevationGainMeters
- bikeFacilityType
- protectionLevel
- roadClass
- surfaceType
- turnType
- intersectionStressScore
- segmentStressScore
- roadBikeSuitabilityScore
- confidenceScore
- accessRules
```

```
RouteCandidate
- id
- label
- strategyType
- segments
- totalDistanceMeters
- etaSeconds
- totalElevationGainMeters
- maxGrade
- protectedLanePercent
- bikeFacilityPercent
- roadBikeSuitabilityScore
- routeStressScore
- directnessScore
- confidenceScore
- recommendationReason
- cautionNotes
```

```
RouteScoreBreakdown
- travelTimeScore
- climbPenalty
- maxGradePenalty
- protectedLaneBonus
- bikeLaneBonus
- offStreetBonus
- arterialPenalty
- roughSurfacePenalty
- crossingPenalty
- detourPenalty
- descentPenalty
- finalScore
```

### Apple Music Models

```
AppleMusicConnectionState
- notDetermined
- denied
- authorizedNoSubscription
- authorizedSubscribed
- restricted
```

```
NowPlayingItem
- id
- title
- artist
- artworkURL
- albumTitle
- durationSeconds
- isPlaying
```

```
PlaybackControlsState
- canPlayPause
- canSkipNext
- canSkipPrevious
- queueAvailable
- volumeAvailable
```

### Navigation Models

```
RideNavigationState
- activeRouteID
- currentSegmentIndex
- nextManeuver
- distanceToNextTurnMeters
- currentStreet
- upcomingStreet
- remainingDistanceMeters
- eta
- currentGrade
- climbRemainingMeters
- routeQualityIndicator
- routeConfidenceIndicator
- musicTrayState
```

```
RideScreenCustomization
- layoutMode
- largerControlsEnabled
- highContrastEnabled
- metricsPriority
- musicTrayDefaultExpanded
- visibleSecondaryMetrics
```

---

## ROUTING LOGIC

### Routing Philosophy
LaneLine should recommend the best overall ride for the rider and bike type, not merely the shortest valid route. The route engine should behave like a weighted, explainable graph optimizer with route alternatives generated from different preference profiles.

### Segment-Level Scoring
Every route segment should contribute to the total route score using a weighted function based on:
- travel time
- average and max grade
- elevation gain
- bike facility type
- protection level
- road classification
- surface quality
- crossing stress
- turn complexity
- rider bike type
- rider route preferences

### Example Weighting Behavior by Bike Type
- **Road bike**: strong penalty for rough or unknown surface, strong penalty for steep spikes, stronger preference for protected lanes and calmer roads, moderate tolerance for slightly longer detours if ride quality improves.
- **Gravel bike**: reduced penalty for rough surface, slightly reduced grade penalties, greater tolerance for mixed-surface alternatives.
- **E-bike**: reduced hill and grade penalties, safety and protection still important.

### Candidate Generation Strategy
Generate multiple route profiles rather than one path:
1. Balanced
2. Safer / protected
3. Faster / direct
4. Easier climbing

Then compute route-level summaries and explanations for each.

### Explainability Requirements
For each route recommendation, produce:
- a winning reason
- major tradeoffs
- the main difficult segment types
- what setting change would produce a different route

### Confidence Handling
A route confidence score should drop when:
- surface is unknown on too many segments
- stress proxies are inferred instead of sourced
- segment metadata is incomplete
- route alternatives depend heavily on uncertain attributes

---

## INTEGRATIONS

### Apple Music Integration
The app should use MusicKit and Apple Music APIs for:
- user authorization
- subscription status detection
- now playing state
- playback control
- optional ride playlist start

The Apple Music layer should not be treated as decorative UI. It must expose real service contracts for:
- `requestAuthorization`
- `checkSubscriptionStatus`
- `observeNowPlaying`
- `playPause`
- `skipNext`
- `skipPrevious`
- `startPlaylist`

### Geospatial Integration
The geospatial layer should be explicit about future real-data ingestion:
- bikeway network source input
- street metadata normalization
- elevation enrichment
- segment feature engineering
- route graph creation
- route scoring

---

## Token-Efficient Iteration Template

Use this for later passes instead of resending the full prompt:

```
Context:
LaneLine is an iOS SwiftUI bike routing app for San Francisco with Apple Music-only integration.

Current task:
[insert only the current feature or refactor task]

Read first:
[list only the relevant files]

Constraints:
- Real-data architecture, not visual-only prototype
- Apple Music only via MusicKit
- SwiftUI-first
- Keep navigation primary over music controls
- Do not regress existing route scoring model

Acceptance criteria:
[list concrete acceptance criteria]

Mocking rule:
Use mocks only where required for previews or temporary demo states. Preserve real service interfaces and real data models.
```

### Recommended Tool Usage
- Use Claude Code for: turning this package into repo files, generating or refining Swift models and protocols, implementing services and tests, connecting real datasets, refactoring after Fable's first pass.
- Use Fable for: the initial app build pass, major SwiftUI screen composition, route comparison UX, ride screen UX with Apple Music integration, converting the spec into a coherent app scaffold.

### Best Sequence
1. Prepare repo docs and file structure in Claude Code.
2. Run one strong Fable build using MASTER_PROMPT.
3. Bring output back into Claude Code for cleanup, integration, and iteration.
4. Use the token-efficient iteration template for later Fable passes.

### Source Notes
This package is grounded in real external system requirements: Apple documents MusicKit and subscriber-aware authorization requirements for Apple Music integration, and DataSF / SFMTA publish bikeway network datasets that can serve as real routing inputs.
