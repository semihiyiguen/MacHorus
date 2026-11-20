// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import SwiftUI

/// Rounded container for one group of content.
struct PanelCard<Content: View>: View {
    var spacing: CGFloat = 10
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: Content
    @Environment(\.panelCardFillsHeight) private var fillsHeight
    @Environment(\.panelCardIsFlat) private var isFlat

    var body: some View {
        if isFlat {
            // Inside a widget frame: its parts, without a card of their own.
            VStack(alignment: .leading, spacing: spacing) { content }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            // In a grid row both cards take the row's height, so they end level.
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            )
    }
}

/// Small uppercase heading above a card, optionally with a counter.
struct SectionTitle: View {
    private let title: Text
    private let trailing: String?

    init(title: LocalizedStringKey, trailing: String? = nil) {
        self.title = Text(title)
        self.trailing = trailing
    }

    init(verbatim title: String, trailing: String? = nil) {
        self.title = Text(verbatim: title)
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            title
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.goldText)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// A symbol in its colour on a soft tinted square (like the system's
/// settings and widgets), instead of white on a dark block.
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.lapis
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(Theme.symbolTint(tint))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(tint.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(
                    tint.opacity(0.22), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}

/// Coloured capsule for short states such as "Granted" or "Never".
struct StatusChip: View {
    let text: String
    let symbol: String
    let tone: Tone

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tone.color.opacity(0.14)))
            .fixedSize()
    }
}

/// A labelled number, e.g. "RAM · 14 MB".
struct MetricTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    var tone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05))
        )
    }
}

/// Icon, title and subtitle with a trailing accessory; the building block of lists.
struct InfoRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = Theme.lapis
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// Capsule button used in the panel footer.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .contentShape(Capsule())
    }
}

/// Two to four choices as pills; the selected one in gold. Own control: the
/// system's segmented control drew its selection differently in light and
/// dark offscreen renders.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, title: LocalizedStringKey)]
    @Binding var selection: Value

    var body: some View {
        // One track with the chosen segment raised, like a system control.
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                Capsule().fill(Theme.segmentSelected)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }
}

/// Text tabs with a gold line under the chosen one: the main choice of a
/// card, clearly above the small options next to it.
struct UnderlineTabs<Value: Hashable>: View {
    let options: [(value: Value, title: LocalizedStringKey)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    VStack(spacing: 3) {
                        Text(option.title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                        Capsule()
                            .fill(selected ? Theme.gold : .clear)
                            .frame(height: 2.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// The Bluetooth rune (SF Symbols has no Bluetooth logo), drawn as lines
/// in the current foreground colour.
struct BluetoothGlyph: View {
    var body: some View {
        BluetoothShape()
            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .frame(width: 8, height: 12)
            .accessibilityLabel(Text(verbatim: "Bluetooth"))
    }
}

private struct BluetoothShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0, 0.27))
        path.addLine(to: point(1, 0.73))
        path.addLine(to: point(0.5, 1))
        path.addLine(to: point(0.5, 0))
        path.addLine(to: point(1, 0.27))
        path.addLine(to: point(0, 0.73))
        return path
    }
}

/// Cards stretch to the height they are offered (grid rows). A plain key:
/// the `@Entry` macro needs SwiftUIMacros, which the Command Line Tools lack.
private struct PanelIsShownKey: EnvironmentKey {
    static let defaultValue = true
}

private struct PanelCardFillsHeightKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PanelCardIsFlatKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// False while the popover is closed (its views live on).
    var panelIsShown: Bool {
        get { self[PanelIsShownKey.self] }
        set { self[PanelIsShownKey.self] = newValue }
    }

    var panelCardFillsHeight: Bool {
        get { self[PanelCardFillsHeightKey.self] }
        set { self[PanelCardFillsHeightKey.self] = newValue }
    }

    /// Cards inside a widget frame draw no card of their own.
    var panelCardIsFlat: Bool {
        get { self[PanelCardIsFlatKey.self] }
        set { self[PanelCardIsFlatKey.self] = newValue }
    }
}
