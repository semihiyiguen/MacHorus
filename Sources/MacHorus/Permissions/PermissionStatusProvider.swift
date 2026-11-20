// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AVFoundation
import AppKit
import ApplicationServices
import EventKit
import IOKit.hid
import MacHorusCore
import UserNotifications

/// Reads TCC states without ever showing a prompt. Permissions MacHorus never
/// uses are not read at all, and those whose check lists the app in System
/// Settings are read only when an active feature needs them.
@MainActor
struct PermissionStatusProvider {
    func states(needed: Set<Permission>) async -> [Permission: PermissionState] {
        var states: [Permission: PermissionState] = [:]
        for permission in Permission.allCases where permission.usage == .perFeature {
            if permission.checkRegistersApp && !needed.contains(permission) { continue }
            states[permission] = await state(of: permission)
        }
        return states
    }

    private func state(of permission: Permission) async -> PermissionState {
        switch permission {
        // Accessibility cannot tell "never asked" from "denied".
        case .accessibility: AXIsProcessTrusted() ? .granted : .denied
        case .inputMonitoring: Self.state(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))
        case .camera: Self.state(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: Self.state(AVCaptureDevice.authorizationStatus(for: .audio))
        case .calendars: Self.state(EKEventStore.authorizationStatus(for: .event))
        case .notifications:
            Self.state(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        // Granted per target app when first used; there is no global state.
        case .automation: .notApplicable
        // No public query exists: the last tap MacHorus created tells.
        case .systemAudio:
            switch UserDefaults.standard.string(forKey: SystemAudioAccess.key) {
            case SystemAudioAccess.granted: .granted
            case SystemAudioAccess.denied: .denied
            default: .notDetermined
            }
        // Never used by MacHorus, therefore never read.
        case .screenRecording, .fullDiskAccess, .bluetooth: .notChecked
        }
    }

    /// Opens the matching page in System Settings.
    static func openSystemSettings(for permission: Permission) {
        let anchor: String
        switch permission {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        case .calendars: anchor = "Privacy_Calendars"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .notifications:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            return
        case .automation: anchor = "Privacy_Automation"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        // System audio is a section of the screen recording page.
        case .systemAudio: anchor = "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func state(_ access: IOHIDAccessType) -> PermissionState {
        switch access {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .notDetermined
        }
    }

    private static func state(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    private static func state(_ status: EKAuthorizationStatus) -> PermissionState {
        switch status {
        case .fullAccess: .granted
        case .denied, .restricted, .writeOnly: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    private static func state(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}

/// What the last process tap showed about consent to system audio recording.
enum SystemAudioAccess {
    static let key = "systemAudioAccess"
    static let granted = "granted"
    static let denied = "denied"
}
