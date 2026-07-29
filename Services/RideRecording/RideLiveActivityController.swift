import ActivityKit
import Foundation

/// Starts, updates, and ends the real system Dynamic Island / Lock Screen
/// Live Activity for an active ride. `ActivityAuthorizationInfo` reports
/// whether Live Activities are available (Settings toggle, device support)
/// rather than throwing — this is a no-op, not an error, wherever they're
/// unavailable.
@MainActor
final class RideLiveActivityController {
    private var activity: Activity<RideActivityAttributes>?
    private var lastState: RideActivityAttributes.ContentState?

    func start(routeLabel: String, state: RideActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activity == nil else { return }
        let attributes = RideActivityAttributes(routeLabel: routeLabel)
        let content = ActivityContent(state: state, staleDate: nil)
        activity = try? Activity.request(attributes: attributes, content: content, pushType: nil)
        lastState = state
    }

    /// Ticks arrive every second; the formatted distance/turn text often
    /// hasn't actually changed between them, so this skips redundant calls
    /// into ActivityKit rather than pushing an update every tick regardless.
    func update(_ state: RideActivityAttributes.ContentState) {
        guard let activity, state != lastState else { return }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        let finalState = activity.content.state
        Task { await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
