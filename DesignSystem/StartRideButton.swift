import SwiftUI

/// The ride-launching CTA on the route detail screen. Deliberately styled to
/// stand apart from every other `PrimaryButton` in the app — a glossy,
/// oversized pill with a soft drop shadow for "pressed into the surface"
/// depth, ringed by a blurred rainbow glow that continuously sweeps
/// clockwise. This is the one button on that screen that should be
/// impossible to miss.
struct StartRideButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    @State private var glowRotation: Double = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: LaneLineDesign.Spacing.small) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .bold))
                }
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: LaneLineDesign.HitTarget.large)
        }
        .buttonStyle(DepthButtonStyle())
        .background(glow)
        .onAppear {
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) {
                glowRotation = 360
            }
        }
    }

    /// A rainbow `AngularGradient`, oversized and rotating behind a fixed
    /// ring-shaped mask, so only the ring's colors visibly sweep around the
    /// button rather than the button's outline itself appearing to spin.
    private var glow: some View {
        let ringShape = RoundedRectangle(
            cornerRadius: DepthButtonStyle.cornerRadius + 6, style: .continuous
        )
        return GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height) * 1.8
            AngularGradient(
                colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                center: .center
            )
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .rotationEffect(.degrees(glowRotation))
            .mask(ringShape.strokeBorder(lineWidth: 7).frame(width: proxy.size.width, height: proxy.size.height))
        }
        .blur(radius: 6)
        .opacity(0.9)
        // `.mask()` only clips what's *drawn* — it doesn't shrink this
        // view's own layout bounds, which are still the oversized `side ×
        // side` square used so the rotating gradient always covers the
        // ring. Left as-is, that invisible oversized footprint was still
        // hit-testable, so a tap/scroll starting well above the visible
        // ring (up to roughly half the screen) was being swallowed by this
        // purely decorative layer instead of reaching the button or the
        // ScrollView underneath it.
        .allowsHitTesting(false)
    }
}

/// Glossy vertical-gradient fill, brand-tinted shadow, and a spring
/// press-down scale — reads as thicker and more physically solid than the
/// flat `.borderedProminent` style used elsewhere.
private struct DepthButtonStyle: ButtonStyle {
    static let cornerRadius: CGFloat = LaneLineDesign.CornerRadius.extraLarge

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                LinearGradient(
                    colors: [
                        LaneLineDesign.Colors.primary.opacity(configuration.isPressed ? 0.85 : 1),
                        LaneLineDesign.Colors.primary.opacity(configuration.isPressed ? 0.65 : 0.80),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                    .blendMode(.overlay)
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .shadow(
                color: LaneLineDesign.Colors.primary.opacity(configuration.isPressed ? 0.25 : 0.45),
                radius: configuration.isPressed ? 8 : 18,
                y: configuration.isPressed ? 3 : 10
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

#Preview {
    VStack {
        Spacer()
        StartRideButton(title: "Start Ride", icon: "bicycle") {}
            .padding()
    }
    .background(LaneLineDesign.Colors.background)
}
