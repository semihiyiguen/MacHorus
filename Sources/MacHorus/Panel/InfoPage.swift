// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacHorus contributors

import AppKit
import MacHorusCore
import SwiftUI

/// Like the "About" window of a Mac app: icon, name, version, one line.
struct InfoPage: View {
    private let version = AppIdentity.currentVersion()
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"

    var body: some View {
        VStack(spacing: Theme.pageSpacing) {
            VStack(spacing: 8) {
                Image(nsImage: ImageThumbnail.make(NSApp.applicationIconImage, points: 64))
                    .frame(width: 64, height: 64)
                    .shadow(color: Theme.lapisDeep.opacity(0.35), radius: 10, y: 4)
                    .accessibilityHidden(true)
                Text(AppIdentity.name).font(.system(.title2, design: .rounded).weight(.bold))
                Text("about.version \(version.description) \(build)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("about.tagline")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}
