// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusMonitor
import SwiftUI

/// MacHorus visual identity: lapis blue and gold, taken from the app icon.
enum Theme {
    static let lapis = Color(hex: 0x2B4FB8)
    static let lapisDeep = Color(hex: 0x0B1A45)
    static let gold = Color(hex: 0xE7B940)
    static let goldLight = Color(hex: 0xFBE08A)
    /// Gold for text and small symbols: darker in light mode to stay readable.
    static let goldText = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xE7 / 255.0, green: 0xB9 / 255.0, blue: 0x40 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x9A / 255.0, green: 0x6B / 255.0, blue: 0x00 / 255.0, alpha: 1)
        })
    static let positive = Color(hex: 0x34C759)
    static let attention = Color(hex: 0xFF9F0A)
    /// Red: act now (status points of the overview).
    static let critical = Color(hex: 0xFF453A)

    static let goldGradient = LinearGradient(colors: [goldLight, gold], startPoint: .top, endPoint: .bottom)
    static let lapisGradient = LinearGradient(colors: [lapis, lapisDeep], startPoint: .top, endPoint: .bottom)
    static let positiveGradient = LinearGradient(
        colors: [Color(hex: 0x4CD964), Color(hex: 0x1E9E46)], startPoint: .top, endPoint: .bottom)

    static let panelWidth: CGFloat = 360
    static let pageHeight: CGFloat = 430
    /// Expanded panel: two columns, still below the menu bar of a 13-inch
    /// MacBook (900 pt high).
    static let expandedPanelWidth: CGFloat = 720
    static let expandedPageHeight: CGFloat = 560
    static let cornerRadius: CGFloat = 16
    /// Between cards, and inside them: a little more air than 1.0.21
    /// (between the old density and an airy one).
    static let pageSpacing: CGFloat = 14
    /// Height of one widget row (the fixed grid: 1×1 and 1×2 are one row,
    /// 2×2 and 2×4 two).
    static let widgetRow: CGFloat = 96
    /// Gap between widgets and their inner margin: tight like phone widgets.
    static let widgetSpacing: CGFloat = 12
    static let widgetPadding: CGFloat = 12
    static let cardPadding: CGFloat = 14

    /// Light and dark variants in one colour.
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
            })
    }

    /// Cards: nearly white in light mode, a soft lift in dark mode.
    static let cardFill = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.72, darkAlpha: 0.06)
    static let cardStroke = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    /// The chosen segment of a picker, raised like the system's.
    static let segmentSelected = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.17)
    /// Lapis is too dark for symbols on dark backgrounds.
    static let lapisSymbol = dynamic(light: 0x2B4FB8, dark: 0x7D9DFF)

    static func symbolTint(_ tint: Color) -> Color {
        if tint == lapis { return lapisSymbol }
        if tint == gold { return goldText }
        return tint
    }
}

/// The charge's colour, the same on every gauge: green when full or
/// charging, orange when low, red when almost empty, lapis in between.
enum BatteryTone {
    static func color(charge: Int, onPower: Bool, charging: Bool) -> Color {
        if charging || charge >= 80 { return Theme.positive }
        if !onPower, charge <= 10 { return Theme.critical }
        if !onPower, charge <= 20 { return Theme.attention }
        return Theme.lapis
    }

    /// For the number itself: only a low charge colours it.
    static func valueColor(charge: Int, onPower: Bool) -> Color {
        guard !onPower else { return .primary }
        return charge <= 10 ? Theme.critical : charge <= 20 ? Theme.attention : .primary
    }
}

extension BatterySnapshot {
    var color: Color { BatteryTone.color(charge: charge, onPower: isOnExternalPower, charging: isCharging) }
}

/// Meaning of a status, mapped to one colour everywhere.
enum Tone {
    case positive
    case attention
    /// Red: act now. Always together with a symbol, never by colour alone.
    case critical
    case neutral
    case accent

    var color: Color {
        switch self {
        case .positive: Theme.positive
        case .attention: Theme.attention
        case .critical: Theme.critical
        case .neutral: .secondary
        case .accent: Theme.goldText
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
