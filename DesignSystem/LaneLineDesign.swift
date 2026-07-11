import SwiftUI

/// Design tokens. Colors are defined programmatically with dynamic providers
/// so light/dark adapt without an asset catalog, and the ride screen can
/// switch to high-contrast variants for sunlight legibility.
enum LaneLineDesign {

    // MARK: - Colors

    enum Colors {
        /// Brand blue, tuned brighter in dark mode.
        static let primary = adaptive(
            light: .init(red: 0.00, green: 0.44, blue: 0.85),
            dark: .init(red: 0.25, green: 0.62, blue: 1.00)
        )

        static let background = adaptive(
            light: .init(red: 0.96, green: 0.96, blue: 0.97),
            dark: .init(red: 0.07, green: 0.07, blue: 0.09)
        )
        static let surface = adaptive(
            light: .white,
            dark: .init(red: 0.13, green: 0.13, blue: 0.16)
        )
        static let surfaceSecondary = adaptive(
            light: .init(red: 0.93, green: 0.93, blue: 0.95),
            dark: .init(red: 0.19, green: 0.19, blue: 0.23)
        )

        static let textPrimary = adaptive(
            light: .init(red: 0.10, green: 0.10, blue: 0.15),
            dark: .init(red: 0.95, green: 0.95, blue: 0.97)
        )
        static let textSecondary = adaptive(
            light: .init(red: 0.40, green: 0.40, blue: 0.45),
            dark: .init(red: 0.65, green: 0.65, blue: 0.70)
        )
        static let textTertiary = adaptive(
            light: .init(red: 0.60, green: 0.60, blue: 0.65),
            dark: .init(red: 0.45, green: 0.45, blue: 0.50)
        )

        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red

        /// Route strategy accents.
        static let balanced = primary
        static let saferRoute = adaptive(
            light: .init(red: 0.13, green: 0.60, blue: 0.33),
            dark: .init(red: 0.25, green: 0.78, blue: 0.47)
        )
        static let fasterRoute = adaptive(
            light: .init(red: 0.55, green: 0.27, blue: 0.85),
            dark: .init(red: 0.70, green: 0.48, blue: 1.00)
        )
        static let easierClimbing = adaptive(
            light: .init(red: 0.88, green: 0.50, blue: 0.10),
            dark: .init(red: 1.00, green: 0.65, blue: 0.25)
        )

        static func strategy(_ strategy: RouteStrategyType) -> Color {
            switch strategy {
            case .balanced: return balanced
            case .safer: return saferRoute
            case .faster: return fasterRoute
            case .easierClimbing: return easierClimbing
            }
        }

        /// Grade severity for elevation displays and live grade pills.
        static func grade(_ decimal: Double) -> Color {
            switch abs(decimal) {
            case ..<0.03: return success
            case ..<0.06: return .yellow
            case ..<0.09: return warning
            default: return danger
            }
        }

        /// 0...1 stress (low is calm).
        static func stress(_ value: Double) -> Color {
            switch value {
            case ..<0.35: return success
            case ..<0.55: return warning
            default: return danger
            }
        }

        private struct RGB {
            let red: Double
            let green: Double
            let blue: Double

            static let white = RGB(red: 1, green: 1, blue: 1)

            init(red: Double, green: Double, blue: Double) {
                self.red = red
                self.green = green
                self.blue = blue
            }
        }

        private static func adaptive(light: RGB, dark: RGB) -> Color {
            Color(UIColor { traits in
                let rgb = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1
                )
            })
        }
    }

    // MARK: - Typography

    enum Typography {
        static let navigationTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let sectionHeader = Font.system(.title3, design: .rounded).weight(.semibold)
        static let body = Font.system(.body)
        static let caption = Font.system(.caption)
        /// Large glanceable numbers on the ride screen.
        static let metricValue = Font.system(.title, design: .rounded).weight(.bold)
        static let metricValueLarge = Font.system(.largeTitle, design: .rounded).weight(.heavy)
        static let metricLabel = Font.system(.caption, design: .rounded)
        static let mono = Font.system(.caption, design: .monospaced)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xlarge: CGFloat = 32
        static let xxlarge: CGFloat = 48
    }

    // MARK: - Corner Radius

    enum CornerRadius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 24
    }

    // MARK: - Hit Targets (mounted-phone use)

    enum HitTarget {
        static let minimum: CGFloat = 44
        static let comfortable: CGFloat = 56
        /// "Larger controls" ride-screen mode.
        static let large: CGFloat = 68
    }
}
