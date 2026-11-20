// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import SwiftUI

/// History line with a soft fill, drawn in one Canvas pass (no view per point).
/// Live values are never animated: each animation would redraw the panel at
/// display refresh rate for a fraction of every sampling interval.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.lapis
    var capacity: Int

    var body: some View {
        Canvas { context, size in
            // Baseline, so a history that is still filling up reads as a chart.
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(.primary.opacity(0.12)), lineWidth: 1)
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max(1, capacity - 1))
            let offset = CGFloat(capacity - values.count) * step
            func point(_ index: Int) -> CGPoint {
                let value = min(1, max(0, values[index]))
                return CGPoint(x: offset + CGFloat(index) * step, y: size.height * (1 - CGFloat(value)))
            }
            var line = Path()
            line.move(to: point(0))
            for index in values.indices.dropFirst() { line.addLine(to: point(index)) }
            var area = line
            area.addLine(to: CGPoint(x: point(values.count - 1).x, y: size.height))
            area.addLine(to: CGPoint(x: offset, y: size.height))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// Horizontal bar for a value between 0 and 1.
struct MeterBar: View {
    let value: Double
    var color: Color = Theme.lapis
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Bar split into coloured segments (e.g. app, wired, compressed memory).
struct StackedBar: View {
    struct Segment: Identifiable {
        let id: String
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, geometry.size.width * min(1, max(0, segment.fraction)) - 1.5))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One vertical bar per CPU core.
struct CoreBars: View {
    let loads: [Double]
    let colors: [Color]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(loads.indices, id: \.self) { index in
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(colors[index])
                            .frame(height: max(2, geometry.size.height * min(1, max(0, loads[index]))))
                    }
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.primary.opacity(0.06)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A value as a ring with the number in the middle. Not animated: live
/// values must not redraw at the display rate (docs/MEASUREMENTS.md).
struct RingGauge: View {
    let value: Double?
    let text: String
    let title: LocalizedStringKey
    var color: Color = Theme.lapis
    var size: CGFloat = 62

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.primary.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(1, max(0, value ?? 0)))
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.6), value: value)
                Text(verbatim: text)
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.6), value: text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 8)
            }
            .frame(width: size, height: size)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
