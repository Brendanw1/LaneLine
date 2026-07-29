import ActivityKit

/// The Live Activity shown in the Dynamic Island and on the Lock Screen
/// during an active ride. Visible to both `LaneLine` (which starts/updates
/// it from `ActiveRideModel`) and `LaneLineWidgets` (which renders it) —
/// content is pre-formatted display strings rather than domain types
/// (`RouteSegment`, `TurnType`, …) on purpose, so the widget extension
/// doesn't need to link the app's routing model at all.
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var turnSystemImageName: String
        var turnInstruction: String
        var distanceToTurnText: String
        var currentStreet: String
    }

    let routeLabel: String
}
