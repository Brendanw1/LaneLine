import SwiftUI

// MARK: - Badges

/// Pill badge naming a route strategy, tinted with its accent color.
struct StrategyBadge: View {
    let strategy: RouteStrategyType
    var isRecommended = false

    var body: some View {
        HStack(spacing: 4) {
            if isRecommended {
                Image(systemName: "star.fill").font(.system(size: 9))
            }
            Text(isRecommended ? "Recommended" : strategy.displayName)
        }
        .font(LaneLineDesign.Typography.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(LaneLineDesign.Colors.strategy(strategy))
        .clipShape(Capsule())
    }
}

/// Marks a route that actually threads through SF's real Wiggle corridor.
/// See `WiggleCorridor`.
struct WiggleBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.swap").font(.system(size: 9))
            Text("Via the Wiggle")
        }
        .font(LaneLineDesign.Typography.caption.weight(.semibold))
        .foregroundStyle(LaneLineDesign.Colors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .wiggleGlow(cornerRadius: 100)
    }
}

/// Small pill showing a facility/protection descriptor on segment rows.
struct FacilityBadge: View {
    let facility: BikeFacilityType
    let protection: ProtectionLevel

    var body: some View {
        Text(label)
            .font(LaneLineDesign.Typography.caption)
            .foregroundStyle(LaneLineDesign.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(LaneLineDesign.Colors.surfaceSecondary)
            .clipShape(Capsule())
    }

    private var label: String {
        switch facility {
        case .offStreetPath: return "Car-free path"
        case .protectedBikeLane: return "Protected lane"
        case .bikeLane: return protection == .buffered ? "Buffered lane" : "Bike lane"
        case .sharedLane: return "Shared lane"
        case .bikeRoute: return "Bike route"
        case .mixedTraffic: return "No bike facility"
        case .unknown: return "Unknown facility"
        }
    }
}

// MARK: - Metrics

/// Labeled stat used across comparison cards and the detail screen.
struct MetricTile: View {
    let label: String
    let value: String
    var icon: String?
    var tint: Color = LaneLineDesign.Colors.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(label)
            }
            .font(LaneLineDesign.Typography.metricLabel)
            .foregroundStyle(LaneLineDesign.Colors.textSecondary)

            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Compact icon + label + value row.
struct RouteMetricRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(LaneLineDesign.Colors.textSecondary)
            Text(label)
                .font(LaneLineDesign.Typography.caption)
                .foregroundStyle(LaneLineDesign.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(LaneLineDesign.Typography.caption.weight(.medium))
                .foregroundStyle(LaneLineDesign.Colors.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal 0...1 quality bar with severity color.
struct QualityIndicator: View {
    let value: Double
    let label: String
    /// When true, high values are good (suitability); when false, low values
    /// are good (stress).
    var higherIsBetter = true

    private var color: Color {
        let goodness = higherIsBetter ? value : 1 - value
        switch goodness {
        case 0.65...: return LaneLineDesign.Colors.success
        case 0.4..<0.65: return LaneLineDesign.Colors.warning
        default: return LaneLineDesign.Colors.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(RideFormat.score(value))
            }
            .font(LaneLineDesign.Typography.metricLabel)
            .foregroundStyle(LaneLineDesign.Colors.textSecondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LaneLineDesign.Colors.surfaceSecondary)
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * min(1, max(0, value)))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(RideFormat.score(value)) out of 10")
    }
}

// MARK: - Buttons

/// Full-width primary action button sized for outdoor use.
struct PrimaryButton: View {
    let title: String
    var icon: String?
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: LaneLineDesign.Spacing.small) {
                if let icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: LaneLineDesign.HitTarget.comfortable)
        }
        .buttonStyle(.borderedProminent)
        .tint(role == .destructive ? LaneLineDesign.Colors.danger : LaneLineDesign.Colors.primary)
    }
}

// MARK: - Cards

/// Standard card container.
struct CardContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(LaneLineDesign.Spacing.medium)
            .background(LaneLineDesign.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

// MARK: - Previews

#Preview("Components") {
    VStack(alignment: .leading, spacing: 16) {
        HStack {
            StrategyBadge(strategy: .balanced, isRecommended: true)
            StrategyBadge(strategy: .safer)
            StrategyBadge(strategy: .faster)
        }
        FacilityBadge(facility: .protectedBikeLane, protection: .fullyProtected)
        HStack(spacing: 24) {
            MetricTile(label: "ETA", value: "23 min", icon: "clock")
            MetricTile(label: "Climb", value: "48 m", icon: "arrow.up.right")
            MetricTile(label: "Max grade", value: "9%", icon: "triangle", tint: LaneLineDesign.Colors.warning)
        }
        QualityIndicator(value: 0.82, label: "Road-bike fit")
        QualityIndicator(value: 0.25, label: "Route stress", higherIsBetter: false)
        PrimaryButton(title: "Start Ride", icon: "location.fill") {}
    }
    .padding()
    .background(LaneLineDesign.Colors.background)
}
