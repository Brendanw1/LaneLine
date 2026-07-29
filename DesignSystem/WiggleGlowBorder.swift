import SwiftUI

/// A frosty animated border that doesn't just trace a shape's outline but
/// undulates along it — a small, literal echo of the real Wiggle route's
/// zigzag streets. Marks the one surface in the app tied to that specific
/// place: the "Prefer the Wiggle" toggle and its "Via the Wiggle" badge.
struct WiggleGlowBorder: View {
    var cornerRadius: CGFloat
    /// How far the glow displaces from the shape's true edge, in points.
    var amplitude: CGFloat = 3
    /// Arc length of one full wiggle cycle, in points.
    var wavelength: CGFloat = 26

    @State private var phase: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            wigglyOutline
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.9), .cyan.opacity(0.55), .white.opacity(0.9)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    lineWidth: 3
                )
                .blur(radius: 5)
                .opacity(0.85)

            wigglyOutline
                .stroke(.white.opacity(0.95), lineWidth: 1.25)
        }
        // Purely decorative — never steal touches meant for the content or
        // control this decorates.
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                phase = 2 * .pi
            }
        }
    }

    private var wigglyOutline: WigglyRoundedRect {
        WigglyRoundedRect(cornerRadius: cornerRadius, amplitude: amplitude, wavelength: wavelength, phase: phase)
    }
}

/// A rounded rectangle whose outline is displaced perpendicular to its own
/// perimeter by a traveling sine wave, rather than tracing a clean edge.
/// Sampled at fixed arc-length steps across all four straight edges and
/// four rounded corners so the wiggle reads continuously through corners
/// instead of resetting at each one.
private struct WigglyRoundedRect: Shape {
    var cornerRadius: CGFloat
    var amplitude: CGFloat
    var wavelength: CGFloat
    var phase: Double

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let straightH = rect.width - 2 * r
        let straightV = rect.height - 2 * r
        let quarterArc = r * .pi / 2
        let perimeter = 2 * straightH + 2 * straightV + 4 * quarterArc
        guard perimeter > 0, wavelength > 0 else {
            return Path(roundedRect: rect, cornerRadius: cornerRadius)
        }

        let stepLength: CGFloat = 3
        let sampleCount = max(8, Int(perimeter / stepLength))

        var points: [CGPoint] = []
        points.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let s = CGFloat(i) / CGFloat(sampleCount) * perimeter
            let (base, normal) = Self.pointAndNormal(
                atArcLength: s, rect: rect, r: r,
                straightH: straightH, straightV: straightV, quarterArc: quarterArc
            )
            let wave = amplitude * CGFloat(
                sin(2 * Double.pi * Double(s / wavelength) + phase)
            )
            points.append(CGPoint(x: base.x + normal.dx * wave, y: base.y + normal.dy * wave))
        }

        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// Walks the rounded rect's perimeter clockwise, starting at the top
    /// edge's leading point, returning the point at arc length `s` and its
    /// outward-pointing unit normal.
    private static func pointAndNormal(
        atArcLength s: CGFloat, rect: CGRect, r: CGFloat,
        straightH: CGFloat, straightV: CGFloat, quarterArc: CGFloat
    ) -> (point: CGPoint, normal: (dx: CGFloat, dy: CGFloat)) {
        var remaining = s

        func corner(center: CGPoint, startAngle: CGFloat, t: CGFloat) -> (CGPoint, (dx: CGFloat, dy: CGFloat)) {
            let angle = startAngle + t * (.pi / 2)
            let dx = cos(angle)
            let dy = sin(angle)
            return (CGPoint(x: center.x + r * dx, y: center.y + r * dy), (dx, dy))
        }

        // 1. Top edge, left to right.
        if remaining <= straightH {
            return (CGPoint(x: rect.minX + r + remaining, y: rect.minY), (0, -1))
        }
        remaining -= straightH

        // 2. Top-right corner.
        if remaining <= quarterArc {
            return corner(
                center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
                startAngle: -.pi / 2, t: remaining / quarterArc
            )
        }
        remaining -= quarterArc

        // 3. Right edge, top to bottom.
        if remaining <= straightV {
            return (CGPoint(x: rect.maxX, y: rect.minY + r + remaining), (1, 0))
        }
        remaining -= straightV

        // 4. Bottom-right corner.
        if remaining <= quarterArc {
            return corner(
                center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                startAngle: 0, t: remaining / quarterArc
            )
        }
        remaining -= quarterArc

        // 5. Bottom edge, right to left.
        if remaining <= straightH {
            return (CGPoint(x: rect.maxX - r - remaining, y: rect.maxY), (0, 1))
        }
        remaining -= straightH

        // 6. Bottom-left corner.
        if remaining <= quarterArc {
            return corner(
                center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                startAngle: .pi / 2, t: remaining / quarterArc
            )
        }
        remaining -= quarterArc

        // 7. Left edge, bottom to top.
        if remaining <= straightV {
            return (CGPoint(x: rect.minX, y: rect.maxY - r - remaining), (-1, 0))
        }
        remaining -= straightV

        // 8. Top-left corner (clamped: floating-point drift can push the
        // last sample a hair past the true perimeter).
        return corner(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            startAngle: .pi, t: min(1, remaining / quarterArc)
        )
    }
}

private struct WiggleGlowModifier: ViewModifier {
    let cornerRadius: CGFloat
    let active: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                WiggleGlowBorder(cornerRadius: cornerRadius)
            }
        }
    }
}

extension View {
    /// A frosty border that wiggles along the shape's outline — see
    /// `WiggleGlowBorder`. `active` lets a toggle only glow while enabled.
    func wiggleGlow(cornerRadius: CGFloat, active: Bool = true) -> some View {
        modifier(WiggleGlowModifier(cornerRadius: cornerRadius, active: active))
    }
}

#Preview("Wiggle glow") {
    VStack(spacing: 24) {
        Text("Prefer the Wiggle")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .wiggleGlow(cornerRadius: 100)

        Text("Via the Wiggle")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .wiggleGlow(cornerRadius: 8)
    }
    .padding(40)
    .background(Color.black)
}
