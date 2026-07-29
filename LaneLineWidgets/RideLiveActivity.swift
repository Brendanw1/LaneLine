import ActivityKit
import WidgetKit
import SwiftUI

/// Real system Dynamic Island / Lock Screen presence for an active ride —
/// not an in-app lookalike. Renders from whatever `RideLiveActivityController`
/// last pushed into the activity's `ContentState`.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenRideView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.turnSystemImageName)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.distanceToTurnText)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.turnInstruction)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("on \(context.state.currentStreet)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } compactLeading: {
                Image(systemName: context.state.turnSystemImageName)
                    .foregroundStyle(.white)
            } compactTrailing: {
                Text(context.state.distanceToTurnText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.turnSystemImageName)
                    .foregroundStyle(.white)
            }
            .keylineTint(.blue)
        }
    }
}

private struct LockScreenRideView: View {
    let context: ActivityViewContext<RideActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.state.turnSystemImageName)
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.turnInstruction)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("on \(context.state.currentStreet)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            Text(context.state.distanceToTurnText)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(16)
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.white)
    }
}
