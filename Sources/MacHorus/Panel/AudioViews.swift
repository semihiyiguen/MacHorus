// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import CoreAudio
import MacHorusMonitor
import MacHorusTools
import SwiftUI

/// Sound and microphones in one box, on the overview (the first thing the
/// eye shows): mute every microphone, see who uses it, and turn single apps
/// down or off. Read every 2 s while the box is on screen, never otherwise.
struct AudioBox: View {
    let microphones: MicrophoneController
    let mixer: AudioMixerController
    let devices: AudioDeviceController
    /// `-debug.audioShowsAll YES` opens the list (renders).
    @State private var showsAll = UserDefaults.standard.bool(forKey: "debug.audioShowsAll")
    @Environment(\.panelIsShown) private var panelIsShown

    var body: some View {
        PanelCard(spacing: 10) {
            HStack(spacing: 10) {
                IconTile(
                    symbol: microphones.isMuted ? "mic.slash.fill" : "speaker.wave.2.fill",
                    tint: microphones.isMuted ? Theme.gold : Theme.lapis, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("audio.box.title").font(.callout.weight(.semibold))
                    if microphones.isMuted {
                        Text(
                            microphones.unmutable.isEmpty
                                ? String(localized: "tools.mic.allMuted")
                                : String(
                                    localized:
                                        "tools.mic.someLive \(microphones.unmutable.map(\.name).joined(separator: ", "))"
                                )
                        )
                        .font(.caption)
                        .foregroundStyle(Theme.goldText)
                    } else {
                        UsageLine(
                            symbol: "mic.fill", names: microphones.inputUsers, tone: .attention,
                            some: "tools.mic.usedBy", none: "tools.mic.usedByNone")
                    }
                }
                Spacer(minLength: 0)
            }
            if microphones.isEnabled {
                Button {
                    microphones.setMuted(!microphones.isMuted)
                } label: {
                    Label(
                        microphones.isMuted ? "tools.mic.unmute" : "tools.mic.mute",
                        systemImage: microphones.isMuted ? "mic" : "mic.slash"
                    )
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(microphones.isMuted ? Color.primary : Theme.lapisDeep)
                    .background(
                        Capsule().fill(
                            microphones.isMuted
                                ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(Theme.goldGradient))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if devices.isEnabled {
                // Side by side so the app rows fit without scrolling (user
                // feedback); long names shorten in the middle.
                HStack(spacing: 6) {
                    DeviceMenu(
                        symbol: "speaker.wave.2", label: "audio.devices.output", devices: devices.outputs,
                        current: devices.output
                    ) { devices.select($0, .output) }
                    DeviceMenu(
                        symbol: "mic", label: "audio.devices.input", devices: devices.inputs, current: devices.input
                    ) { devices.select($0, .input) }
                }
                if let volume = devices.volume {
                    MainVolumeRow(level: volume, muted: devices.isOutputMuted, devices: devices)
                }
            }
            if mixer.isEnabled {
                mixerRows
            } else if !microphones.outputUsers.isEmpty {
                UsageLine(
                    symbol: "speaker.wave.2.fill", names: microphones.outputUsers, tone: .neutral,
                    some: "tools.sound.playedBy", none: "tools.sound.playedBy")
            }
        }
        // States change without a notification; read while the box shows.
        .onAppear {
            microphones.refresh()
            if devices.isEnabled { devices.startWatching() }
        }
        .onDisappear { devices.stopWatching() }
        // Back from System Settings: switched on there, it works without a restart.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if mixer.access == SystemAudioAccess.denied { mixer.requestAccess() }
        }
        .onChange(of: devices.isEnabled) { _, enabled in
            enabled ? devices.startWatching() : devices.stopWatching()
        }
        .task(id: panelIsShown) {
            // The popover keeps its views when it closes; stop with it.
            while panelIsShown, !Task.isCancelled {
                // One read of the audio processes serves both parts.
                let processes = await OffMain.run { AudioProcesses.list() }
                guard panelIsShown, !Task.isCancelled else { break }
                let apps = AudioApps.group(processes, responsibility: mixer.responsibility)
                microphones.updateUsers(apps)
                mixer.refresh(with: apps)
                if devices.isEnabled { devices.refreshVolume() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Apps that play or are turned down come first; the rest on request.
    @ViewBuilder private var mixerRows: some View {
        let featured = mixer.apps.filter {
            $0.usesOutput || mixer.muted.contains($0.id) || mixer.volume(of: $0.id) < AudioMixerController.unity
        }
        let rest = mixer.apps.filter { app in !featured.contains { $0.id == app.id } }
        if mixer.apps.isEmpty {
            Text("tools.mixer.nonePlaying").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(featured) { app in MixerRow(app: app, mixer: mixer) }
        if showsAll {
            ForEach(rest) { app in MixerRow(app: app, mixer: mixer) }
        }
        if !rest.isEmpty {
            Button {
                // The widget grows down to show them (no scrolling).
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { showsAll.toggle() }
            } label: {
                Label(
                    showsAll
                        ? String(localized: "audio.box.fewer")
                        : String(localized: "audio.box.more \(String(rest.count))"),
                    systemImage: showsAll ? "chevron.up" : "chevron.down"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.goldText)
            }
            .buttonStyle(.plain)
        }
        AccessNote(mixer: mixer)
    }
}

/// Consent for "System Audio Recording": asked with a button instead of
/// on the first drag; after a refusal the exact place in System Settings.
private struct AccessNote: View {
    let mixer: AudioMixerController

    var body: some View {
        switch mixer.access {
        case SystemAudioAccess.granted:
            EmptyView()
        case SystemAudioAccess.denied:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.attention)
                    Text("tools.mixer.denied").font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("tools.mixer.deniedHow").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("tools.mixer.askAgain") { mixer.requestAccess() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(mixer.isAsking)
                    Button("tools.mixer.openSettings") {
                        PermissionStatusProvider.openSystemSettings(for: .systemAudio)
                    }
                    .buttonStyle(PillButtonStyle())
                }
                .font(.caption)
            }
        default:
            HStack(alignment: .center, spacing: 8) {
                Text("tools.mixer.privacy")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("tools.mixer.allow") { mixer.requestAccess() }
                    .buttonStyle(PillButtonStyle())
                    .font(.caption)
                    .disabled(mixer.isAsking)
            }
        }
    }
}

/// The whole Mac's level, as the volume keys and Control Center set it.
private struct MainVolumeRow: View {
    let level: Float
    let muted: Bool
    let devices: AudioDeviceController

    var body: some View {
        HStack(spacing: 6) {
            Button {
                devices.toggleOutputMute()
            } label: {
                Image(systemName: symbol)
                    .font(.callout)
                    .foregroundStyle(muted ? Theme.goldText : Color.primary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(muted ? "audio.volume.unmute" : "audio.volume.mute"))
            .accessibilityLabel(Text(muted ? "audio.volume.unmute" : "audio.volume.mute"))
            Slider(value: Binding(get: { Double(level) }, set: { devices.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .tint(Theme.gold)
                .accessibilityLabel(Text("audio.volume.title"))
            Text(verbatim: muted ? "–" : MonitorFormat.percent(Int((level * 100).rounded())))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            // Same width as the mute buttons of the app rows below.
            Color.clear.frame(width: 22, height: 1)
        }
        .help(Text("audio.volume.title"))
    }

    private var symbol: String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// The Mac's output or input as a compact menu: the current device's name,
/// a click lists the others (as Control Center does).
private struct DeviceMenu: View {
    let symbol: String
    let label: LocalizedStringKey
    let devices: [AudioDevice]
    let current: AudioObjectID?
    let select: (AudioObjectID) -> Void

    var body: some View {
        Menu {
            ForEach(devices) { device in
                Button {
                    select(device.id)
                } label: {
                    if device.id == current {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption).foregroundStyle(Theme.goldText)
                Text(verbatim: devices.first { $0.id == current }.map { Self.short($0.name) } ?? "–")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(Text(verbatim: devices.first { $0.id == current }?.name ?? ""))
        .accessibilityLabel(Text(label))
    }

    /// "MacBook Pro-Lautsprecher" → "Lautsprecher": the built-in devices
    /// carry the Mac's model name, which leaves no room side by side.
    static func short(_ name: String) -> String {
        let models = [
            "MacBook Pro", "MacBook Air", "MacBook Neo", "MacBook", "iMac", "Mac mini", "Mac Studio", "Mac Pro",
        ]
        for model in models where name.hasPrefix(model) {
            let rest = name.dropFirst(model.count).drop { $0 == "-" || $0 == " " || $0 == "\u{2011}" }
            if !rest.isEmpty { return String(rest.prefix(1).uppercased() + rest.dropFirst()) }
        }
        return name
    }
}

/// "Used by: Teams, Zoom" in one line; names in their own colour.
struct UsageLine: View {
    let symbol: String
    let names: [String]
    let tone: Tone
    let some: String
    let none: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(names.isEmpty ? Color.secondary : tone.color)
                .frame(width: 16)
            Text(
                verbatim: names.isEmpty
                    ? Bundle.main.localizedString(forKey: none, value: nil, table: nil)
                    : Bundle.main.localizedString(forKey: some, value: nil, table: nil) + " "
                        + names.joined(separator: ", ")
            )
            .font(.caption)
            .foregroundStyle(names.isEmpty ? Color.secondary : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MixerRow: View {
    let app: AudioApp
    let mixer: AudioMixerController

    var body: some View {
        let muted = mixer.muted.contains(app.id)
        let level = mixer.volume(of: app.id)
        // One line per app (name, slider, level, mute) keeps the box short.
        HStack(spacing: 6) {
            Image(nsImage: icon)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            HStack(spacing: 3) {
                Text(verbatim: app.name).font(.caption.weight(.semibold)).lineLimit(1)
                if app.usesOutput {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(Theme.goldText)
                        .help(Text("tools.mixer.isPlaying"))
                }
                if mixer.failed.contains(app.id) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.attention)
                        .help(Text("tools.mixer.failed"))
                }
            }
            .frame(maxWidth: 110, alignment: .leading)
            Slider(
                value: Binding(get: { Double(level) }, set: { mixer.setVolume(Float($0), for: app.id) }), in: 0...1
            )
            .controlSize(.mini)
            .disabled(muted)
            .accessibilityLabel(Text(verbatim: app.name))
            Text(verbatim: muted ? "–" : MonitorFormat.percent(Int((level * 100).rounded())))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            Button {
                mixer.toggleMute(app.id)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(muted ? Theme.goldText : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(muted ? Theme.gold.opacity(0.18) : .primary.opacity(0.06)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text(muted ? "tools.mixer.unmute" : "tools.mixer.mute"))
            .accessibilityLabel(Text(muted ? "tools.mixer.unmute" : "tools.mixer.mute"))
        }
    }

    private var icon: NSImage {
        if let identity = ProcessInspector.identity(of: app.pid) { return ProcessActions.icon(for: identity) }
        return ImageThumbnail.make(NSWorkspace.shared.icon(for: .application), points: 18)
    }
}
