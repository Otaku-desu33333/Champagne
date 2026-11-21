//
//  SparkleView.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Sparkle
import SwiftUI

enum SparkleUpdateConfiguration {
    /// Sparkle is usable only when its HTTPS feed and EdDSA public key are set.
    /// A missing key means this build cannot verify updates and must not start
    /// scheduled checks or expose a nonfunctional update command.
    static var isConfigured: Bool {
        guard let feedString = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feed = URL(string: feedString),
              feed.scheme?.lowercased() == "https",
              feed.host != nil,
              let keyString = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let keyData = Data(base64Encoded: keyString.trimmingCharacters(in: .whitespacesAndNewlines)),
              keyData.count == 32
        else { return false }
        return true
    }
}

struct SparkleView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    @ObservedObject private var updaterDelegate = SparkleUpdaterDelegate.shared
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        // When a scheduled check has gently flagged an update, relabel the menu
        // item so the deferred update is easy to act on.
        Button(
            updaterDelegate.updateAvailable ? "check.updates.available" : "check.updates",
            action: updater.checkForUpdates
        )
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// This view model class publishes when new updates can be checked by the user.
/// Main-actor isolated like `SPUUpdater` itself (Sparkle 2.10).
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
