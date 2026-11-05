import AppKit
import SwiftUI

/// Ballast's visual world, "Chart Under Glass": the disk is read like a
/// nautical chart. Open water (free space) is the plain ground, the weight
/// on the disk is drawn in depth bands (the more it weighs, the deeper the
/// blue), what can't be moved (System) is land, and chart magenta marks
/// only hazards the user can act on. Tools float above the chart on
/// Liquid Glass. Every color here is defined once, for day (light) and
/// night (dark) charts, with stronger values under Increase Contrast.
enum Theme {
    // MARK: Ground

    /// Open water: the content background.
    static let water = dynamic(light: 0xF7FAFB, dark: 0x0B1A26, lightHC: 0xFFFFFF, darkHC: 0x050E16)
    /// A step up from the water, for grouped surfaces that sit on it.
    static let shoal = dynamic(light: 0xEDF4F7, dark: 0x12263A, lightHC: 0xE3EDF2, darkHC: 0x1A3349)
    /// Land: what can't be moved. Only the System segment and its legend.
    static let land = dynamic(light: 0xE9DDBB, dark: 0x4A4130, lightHC: 0xD8C796, darkHC: 0x5E5238)
    /// The hairline every contour and divider is drawn with.
    static let contour = dynamic(light: 0x2E6F93, dark: 0x6FB3D6, alpha: 0.18, hcAlpha: 0.4)

    // MARK: Depth (data)

    /// Five depth bands, shallow to deep. Size, weight and emphasis step
    /// through these and nothing else. In a night chart deep water is the
    /// brightest band, so "heavier" always reads as "stronger".
    static let depth: [Color] = [
        dynamic(light: 0xD3E7F0, dark: 0x1F3D52, lightHC: 0xB9D8E6, darkHC: 0x2A5470),
        dynamic(light: 0xA2CBDD, dark: 0x2D5D7A, lightHC: 0x83B6CE, darkHC: 0x3A7499),
        dynamic(light: 0x5F9EC0, dark: 0x4A8DB3, lightHC: 0x3F86AE, darkHC: 0x63A7CF),
        dynamic(light: 0x2A6890, dark: 0x79BADC, lightHC: 0x1C557B, darkHC: 0x95CDEA),
        dynamic(light: 0x123049, dark: 0xBFE3F4, lightHC: 0x0A2236, darkHC: 0xDDF1FA),
    ]

    /// The tint for controls, selection and data marks (depth band 4).
    static var sea: Color { depth[3] }
    /// Ink: the one opaque plate per screen (the primary action) and the
    /// deepest band.
    static var ink: Color { depth[4] }
    /// Text and symbols that sit on an ink plate.
    static let onInk = dynamic(light: 0xF7FAFB, dark: 0x0B1A26, lightHC: 0xFFFFFF, darkHC: 0x000000)

    /// Chart magenta: hazards the user can act on (low space, items that
    /// need a decision). Never decoration.
    static let hazard = dynamic(light: 0xA8126A, dark: 0xF26BB5, lightHC: 0x8A0A55, darkHC: 0xFF8CC8)

    /// A color for a value between 0 and 1 on the depth scale, blended
    /// between bands so treemap tiles step smoothly.
    static func depth(_ fraction: Double) -> Color {
        let clamped = min(max(fraction, 0), 1)
        let index = min(Int((clamped * Double(depth.count - 1)).rounded()), depth.count - 1)
        return depth[index]
    }

    // MARK: Type

    /// Soundings: every byte figure in a list, set like the depth numbers
    /// on a chart (italic, tabular, so columns line up and don't jitter).
    static let sounding = Font.body.italic().monospacedDigit()
    static let soundingSmall = Font.callout.italic().monospacedDigit()
    /// The one figure that owns a screen (free space on Overview, a
    /// folder's size in Explorer, reclaimable bytes on the list).
    static func hero(_ size: CGFloat = 44) -> Font {
        .system(size: size, weight: .semibold, design: .default).italic().monospacedDigit()
    }

    // MARK: Shape

    enum Radius {
        static let bar: CGFloat = 7
        static let tile: CGFloat = 8
        static let row: CGFloat = 12
        static let card: CGFloat = 18
        static let panel: CGFloat = 24
    }

    enum Space {
        static let rowY: CGFloat = 9
        static let gap: CGFloat = 12
        static let inset: CGFloat = 16
        static let section: CGFloat = 32
        static let pageX: CGFloat = 36
        static let contentMax: CGFloat = 820
    }

    // MARK: Helpers

    private static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil,
                                alpha: CGFloat = 1, hcAlpha: CGFloat? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua,
                                                    .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            let hex: UInt32
            var a = alpha
            switch match {
            case .darkAqua?: hex = dark
            case .accessibilityHighContrastAqua?: hex = lightHC ?? light; a = hcAlpha ?? alpha
            case .accessibilityHighContrastDarkAqua?: hex = darkHC ?? dark; a = hcAlpha ?? alpha
            default: hex = light
            }
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        })
    }
}
