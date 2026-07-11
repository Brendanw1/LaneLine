import SwiftUI

// Centralized Liquid Glass adoption. The app deploys to iOS 17, so every
// glass surface routes through these helpers: real `glassEffect` on iOS 26+,
// an ultra-thin material on earlier systems, and an opaque surface when the
// rider enables high contrast — sunlight legibility on a handlebar beats
// translucency.

private struct OpaqueRideSurfacesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set from `RideScreenCustomization.highContrastEnabled` so every glass
    /// surface under the ride screen degrades to opaque together.
    var prefersOpaqueRideSurfaces: Bool {
        get { self[OpaqueRideSurfacesKey.self] }
        set { self[OpaqueRideSurfacesKey.self] = newValue }
    }
}

private struct RideGlassModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.prefersOpaqueRideSurfaces) private var prefersOpaque

    let shape: S
    let interactive: Bool

    func body(content: Content) -> some View {
        if prefersOpaque {
            content
                .background(LaneLineDesign.Colors.surface, in: shape)
                .overlay(shape.strokeBorder(.quaternary, lineWidth: 1))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: shape
            )
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// Liquid Glass surface with graceful degradation. Mark controls the
    /// rider touches as `interactive` so the glass responds to the press.
    func rideGlass(in shape: some InsettableShape, interactive: Bool = false) -> some View {
        modifier(RideGlassModifier(shape: shape, interactive: interactive))
    }

    /// Prominent action button: tinted Liquid Glass on iOS 26+, tinted
    /// bordered-prominent earlier. Shape and sizing come from the label.
    @ViewBuilder
    func prominentRideButtonStyle(tint: Color) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
        }
    }
}

/// Groups neighboring glass shapes so they read as one liquid surface and
/// merge when they approach each other on iOS 26; passthrough earlier.
struct RideGlassContainer<Content: View>: View {
    var spacing: CGFloat = LaneLineDesign.Spacing.small
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
