// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import MacHorusMonitor
import Observation

/// Values next to the eye in the menu bar. They are sampled while the panel
/// is closed, so they are a feature of their own (off by default) and stop
/// while the screen sleeps or is locked (docs/ARCHITECTURE.md).
@MainActor
@Observable
final class MenuBarReadouts {
    enum Item: String, CaseIterable, Sendable {
        case cpu
        case memory
        case gpu
        case temperature
        case network
        case battery

        var metric: Metric {
            switch self {
            case .cpu: .cpu
            case .memory: .memory
            case .gpu: .gpu
            case .temperature: .thermal
            case .network: .network
            case .battery: .power
            }
        }
    }

    static let defaultsKey = "menuBarItems"
    static let defaultItems: [Item] = [.cpu, .memory]

    @ObservationIgnored private let monitor: SystemMonitorModel
    @ObservationIgnored private weak var statusItem: NSStatusItem?
    @ObservationIgnored private var isOn = false
    @ObservationIgnored private let screen: ScreenAvailability
    @ObservationIgnored private var lastDrawn: (blocks: [MenuBarBlock], alert: Bool, indicators: [MenuBarIndicator])?
    /// An alert is active: the eye shows a warning badge.
    @ObservationIgnored private var alert = false
    /// Tools that are on (keep awake, microphones muted) show next to the eye.
    @ObservationIgnored private var indicators: [MenuBarIndicator] = []

    /// The chosen values, in the fixed order of `Item.allCases`.
    private(set) var items: [Item]

    func setShown(_ item: Item, _ shown: Bool) {
        var chosen = Set(items)
        if shown { chosen.insert(item) } else { chosen.remove(item) }
        items = supported.filter(chosen.contains)
        UserDefaults.standard.set(items.map(\.rawValue), forKey: Self.defaultsKey)
        updateDemand()
        render()
    }

    /// Values this Mac can show (no battery on a desktop, no temperature or
    /// GPU value where the chip offers none); only these are offered.
    let supported: [Item]

    init(monitor: SystemMonitorModel, screen: ScreenAvailability, hardware: HardwareCapabilities) {
        self.monitor = monitor
        self.screen = screen
        supported = Item.allCases.filter { item in
            switch item {
            case .gpu: hardware.hasGPUStatistics
            case .temperature: hardware.hasCPUTemperature
            case .battery: hardware.hasBattery
            default: true
            }
        }
        let raw = UserDefaults.standard.stringArray(forKey: Self.defaultsKey)
        let chosen = raw.map { Set($0.compactMap(Item.init(rawValue:))) } ?? Set(Self.defaultItems)
        items = supported.filter(chosen.contains)
        monitor.addRoundHandler(owner: self) { [weak self] _ in self?.render() }
        screen.onChange { [weak self] _ in self?.updateDemand() }
    }

    func attach(_ statusItem: NSStatusItem) {
        self.statusItem = statusItem
        render()
    }

    func setOn(_ on: Bool) {
        isOn = on
        updateDemand()
        render()
    }

    func setAlert(_ active: Bool) {
        guard active != alert else { return }
        alert = active
        render()
    }

    func setIndicators(_ new: [MenuBarIndicator]) {
        guard new != indicators else { return }
        indicators = new
        render()
    }

    private func updateDemand() {
        let showing = isOn && screen.isAvailable
        monitor.setBackground(showing ? Set(items.map(\.metric)) : [], for: self)
    }

    /// Draws only when a value's text changed.
    private func render() {
        guard let button = statusItem?.button else { return }
        let blocks = isOn ? MenuBarBlock.blocks(for: items, monitor: monitor) : []
        if let lastDrawn, lastDrawn.blocks == blocks, lastDrawn.alert == alert, lastDrawn.indicators == indicators {
            return
        }
        lastDrawn = (blocks, alert, indicators)
        button.image = MenuBarImage.make(blocks: blocks, alert: alert, indicators: indicators)
    }

}

/// A tool that is on, shown as a small symbol next to the eye.
struct MenuBarIndicator: Equatable {
    let symbol: String
    /// Read by VoiceOver.
    let label: String
}

/// One value in the menu bar: a small caption over the value.
struct MenuBarBlock: Equatable {
    let caption: String
    let value: String
    /// The widest text this block can show, so the menu bar does not jitter.
    let widest: String

    @MainActor
    static func blocks(for items: [MenuBarReadouts.Item], monitor: SystemMonitorModel) -> [MenuBarBlock] {
        items.compactMap { item in
            switch item {
            case .cpu:
                MenuBarBlock(
                    caption: "CPU", value: MonitorFormat.percent(monitor.cpu?.total.total),
                    widest: MonitorFormat.percent(100))
            case .memory:
                MenuBarBlock(
                    caption: String(localized: "menubar.caption.memory"),
                    value: MonitorFormat.percent(monitor.memory?.usedFraction), widest: MonitorFormat.percent(100))
            case .gpu:
                MenuBarBlock(
                    caption: "GPU", value: MonitorFormat.percent(monitor.gpu?.utilization),
                    widest: MonitorFormat.percent(100))
            case .temperature:
                MenuBarBlock(
                    caption: String(localized: "menubar.caption.temperature"),
                    value: MonitorFormat.celsius(monitor.thermal?.cpu), widest: "100 °C")
            case .network:
                MenuBarBlock(
                    caption: "↑ " + MenuBarFormat.rate(monitor.network?.uploadBytesPerSecond),
                    value: "↓ " + MenuBarFormat.rate(monitor.network?.downloadBytesPerSecond), widest: "↓ 999 KB/s")
            case .battery:
                monitor.battery.map {
                    MenuBarBlock(
                        caption: String(localized: "menubar.caption.battery"), value: MonitorFormat.percent($0.charge),
                        widest: MonitorFormat.percent(100))
                }
            }
        }
    }
}

enum MenuBarFormat {
    /// Short rates for the narrow menu bar (decimal units like Finder):
    /// "305 B/s", "1,2 KB/s", "18 MB/s".
    static func rate(_ value: Double?) -> String {
        guard let value else { return "–" }
        let units = ["B", "KB", "MB", "GB"]
        var amount = max(0, value)
        var unit = 0
        while amount >= 999.5, unit < units.count - 1 {
            amount /= 1_000
            unit += 1
        }
        let digits = unit > 0 && amount < 9.95 ? 1 : 0
        return amount.formatted(.number.precision(.fractionLength(digits))) + " \(units[unit])/s"
    }
}

/// The eye plus the blocks as one template image: macOS colors it for light
/// and dark menu bars.
@MainActor
enum MenuBarImage {
    private static let name = String(localized: "statusItem.accessibilityLabel")
    private static let eyeImage = NSImage(systemSymbolName: "eye", accessibilityDescription: name)
    private static let alertImage = NSImage(
        systemSymbolName: "eye.trianglebadge.exclamationmark",
        accessibilityDescription: name + ", " + String(localized: "alerts.accessibility"))

    static func make(blocks: [MenuBarBlock], alert: Bool, indicators: [MenuBarIndicator] = []) -> NSImage? {
        let eye = alert ? alertImage : eyeImage
        guard !blocks.isEmpty || !indicators.isEmpty else {
            eye?.isTemplate = true
            return eye
        }
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        let symbols = indicators.compactMap {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
                symbolConfiguration)
        }
        let captionFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: captionFont, .foregroundColor: NSColor.black.withAlphaComponent(0.65),
        ]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
        let widths = blocks.map { block in
            max(
                (block.widest as NSString).size(withAttributes: valueAttributes).width,
                (block.caption as NSString).size(withAttributes: captionAttributes).width
            ).rounded(.up)
        }
        let eyeWidth: CGFloat = 18
        let spacing: CGFloat = 7
        let symbolWidth: CGFloat = 13
        let height: CGFloat = 22
        let symbolsWidth = symbols.isEmpty ? 0 : 3 + CGFloat(symbols.count) * (symbolWidth + 2)
        let blocksWidth = blocks.isEmpty ? 0 : spacing + widths.reduce(0, +) + spacing * CGFloat(blocks.count - 1)
        let width = eyeWidth + symbolsWidth + blocksWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            eye?.draw(in: NSRect(x: 0, y: 4, width: eyeWidth, height: 14))
            var x = eyeWidth + 3
            for symbol in symbols {
                // Centred in its slot, keeping the symbol's own proportions.
                let size = symbol.size
                let scale = min(symbolWidth / size.width, 13 / size.height, 1)
                let drawn = NSSize(width: size.width * scale, height: size.height * scale)
                symbol.draw(
                    in: NSRect(
                        x: x + (symbolWidth - drawn.width) / 2, y: (height - drawn.height) / 2, width: drawn.width,
                        height: drawn.height))
                x += symbolWidth + 2
            }
            x = eyeWidth + symbolsWidth + spacing
            for (block, blockWidth) in zip(blocks, widths) {
                (block.caption as NSString).draw(at: NSPoint(x: x, y: 11.5), withAttributes: captionAttributes)
                (block.value as NSString).draw(at: NSPoint(x: x, y: -0.5), withAttributes: valueAttributes)
                x += blockWidth + spacing
            }
            return true
        }
        image.isTemplate = true
        // VoiceOver reads the values, not just "image".
        image.accessibilityDescription =
            ([eye?.accessibilityDescription ?? name] + indicators.map(\.label)
            + blocks.map { "\($0.caption) \($0.value)" })
            .joined(separator: ", ")
        return image
    }
}

/// The feature module: switching it on shows the values.
@MainActor
final class MenuBarFeature: FeatureModule {
    private let readouts: MenuBarReadouts

    init(readouts: MenuBarReadouts) {
        self.readouts = readouts
    }

    func start() { readouts.setOn(true) }
    func stop() { readouts.setOn(false) }

    static func register(in registry: FeatureRegistry, readouts: MenuBarReadouts) {
        registry.register(FeatureDescriptor(id: "monitor.menubar", category: .menuBar)) {
            MenuBarFeature(readouts: readouts)
        }
    }
}
