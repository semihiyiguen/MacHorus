// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import MacHorusCore
import SwiftUI

/// Display names and symbols for Core types. Literal keys keep
/// scripts/check-localization.py able to verify every string.
enum PanelTexts {
    static func name(_ permission: Permission) -> String {
        switch permission {
        case .accessibility: String(localized: "permission.accessibility")
        case .screenRecording: String(localized: "permission.screenRecording")
        case .inputMonitoring: String(localized: "permission.inputMonitoring")
        case .camera: String(localized: "permission.camera")
        case .microphone: String(localized: "permission.microphone")
        case .calendars: String(localized: "permission.calendars")
        case .fullDiskAccess: String(localized: "permission.fullDiskAccess")
        case .notifications: String(localized: "permission.notifications")
        case .automation: String(localized: "permission.automation")
        case .bluetooth: String(localized: "permission.bluetooth")
        case .systemAudio: String(localized: "permission.systemAudio")
        }
    }

    static func symbol(_ permission: Permission) -> String {
        switch permission {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .inputMonitoring: "keyboard"
        case .camera: "camera"
        case .microphone: "mic"
        case .calendars: "calendar"
        case .fullDiskAccess: "internaldrive"
        case .notifications: "bell.badge"
        case .automation: "gearshape.2"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .systemAudio: "waveform"
        }
    }

    static func title(_ category: FeatureCategory) -> String {
        switch category {
        case .monitor: String(localized: "category.monitor.title")
        case .menuBar: String(localized: "category.menuBar.title")
        case .support: String(localized: "category.support.title")
        case .windows: String(localized: "category.windows.title")
        case .input: String(localized: "category.input.title")
        case .clipboard: String(localized: "category.clipboard.title")
        case .audio: String(localized: "category.audio.title")
        case .display: String(localized: "category.display.title")
        case .tools: String(localized: "category.tools.title")
        case .island: String(localized: "category.island.title")
        }
    }

    static func symbol(_ category: FeatureCategory) -> String {
        switch category {
        case .monitor: "gauge.with.dots.needle.67percent"
        case .menuBar: "menubar.rectangle"
        case .support: "arrow.triangle.2.circlepath"
        case .windows: "macwindow.on.rectangle"
        case .input: "keyboard"
        case .clipboard: "doc.on.clipboard"
        case .audio: "speaker.wave.2"
        case .display: "sun.max"
        case .tools: "wrench.and.screwdriver"
        case .island: "capsule"
        }
    }

    // Keys built at runtime: String(localized:) with interpolation would look
    // up a format key ("feature.%@.title") instead, so ask the bundle directly.
    static func featureTitle(_ id: FeatureID) -> String {
        Bundle.main.localizedString(forKey: "feature.\(id.rawValue).title", value: id.rawValue, table: nil)
    }

    /// One line for the settings list; the full summary is its tooltip.
    static func featureShort(_ id: FeatureID) -> String {
        Bundle.main.localizedString(forKey: "feature.\(id.rawValue).short", value: featureSummary(id), table: nil)
    }

    static func featureSummary(_ id: FeatureID) -> String {
        Bundle.main.localizedString(forKey: "feature.\(id.rawValue).summary", value: "", table: nil)
    }

    /// Each feature gets its own symbol; features of later phases fall back
    /// to their category's.
    static func featureSymbol(_ id: FeatureID, category: FeatureCategory) -> String {
        switch id.rawValue {
        case "monitor.system": "gauge.with.dots.needle.67percent"
        case "monitor.menubar": "menubar.rectangle"
        case "monitor.alerts": "bell.badge"
        case "tools.ports": "point.3.connected.trianglepath.dotted"
        case "support.updates": "arrow.down.app"
        case "support.networkCheck": "stethoscope"
        case "tools.drives": "externaldrive"
        case "tools.hardware": "cable.connector"
        case "tools.printers": "printer"
        case "display.keepAwake": "cup.and.saucer"
        case "audio.micMute": "mic.slash"
        case "audio.mixer": "slider.horizontal.3"
        case "audio.devices": "hifispeaker.and.homepod"
        case "clipboard.history": "doc.on.clipboard"
        default: symbol(category)
        }
    }
}
