import SwiftUI

/// Immersive backdrop for the Now Playing screen: a gradient built from the
/// current track's own artwork color (real MusicKit catalog metadata, not
/// on-device extraction), fading to near-black, with a faint grain layer —
/// the same "blurred colorful gradient plus grain" treatment Apple's own
/// Music app uses on its now-playing background, and for the same reason:
/// a flat two-stop gradient bands visibly at this size, and grain breaks
/// that up cheaply.
struct NowPlayingBackground: View {
    let colorHex: String?
    /// Compact contexts (the ride-screen bar, sitting behind glass rather
    /// than being the screen itself) get a simpler two-stop gradient — no
    /// grain, no safe-area override. The full vertical treatment is sized
    /// and shaped for a near-fullscreen sheet, not a ~60pt-tall strip.
    var compact: Bool = false

    private var baseColor: Color {
        colorHex.flatMap(Color.init(hex:)) ?? LaneLineDesign.Colors.primary
    }

    var body: some View {
        Group {
            if compact {
                LinearGradient(
                    colors: [baseColor.opacity(0.6), baseColor.opacity(0.25)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                ZStack {
                    LinearGradient(
                        colors: [baseColor.opacity(0.85), baseColor.opacity(0.45), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [baseColor.opacity(0.55), .clear],
                        center: .topLeading,
                        startRadius: 10,
                        endRadius: 480
                    )
                    GrainTexture()
                        .blendMode(.overlay)
                }
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.6), value: colorHex)
    }
}

/// A fixed field of low-opacity dots, generated once per appearance and
/// cached rather than redrawn every frame — cheap, and a static grain field
/// reads the same as Apple Music's (it doesn't need to shimmer).
private struct GrainTexture: View {
    @State private var dots: [(x: CGFloat, y: CGFloat, opacity: Double)] = []

    var body: some View {
        Canvas { context, size in
            for dot in dots {
                let rect = CGRect(x: dot.x * size.width, y: dot.y * size.height, width: 1.3, height: 1.3)
                context.opacity = dot.opacity
                context.fill(Path(ellipseIn: rect), with: .color(.white))
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard dots.isEmpty else { return }
            dots = (0..<500).map { _ in
                (CGFloat.random(in: 0...1), CGFloat.random(in: 0...1), Double.random(in: 0.02...0.07))
            }
        }
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// An artwork color used as a UI accent (tint on a slider, an "active"
    /// icon) needs a lightness floor to stay visible against the dark
    /// backdrop above — some album art is genuinely near-black. Hue and
    /// saturation are preserved; only brightness is floored, matching the
    /// "adjust lightness, keep chroma and hue" contrast-fix convention.
    static func legibleAccent(fromHex hex: String?, fallback: Color) -> Color {
        guard let hex, let color = Color(hex: hex) else { return fallback }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation, 0.85), brightness: max(brightness, 0.6))
    }
}
