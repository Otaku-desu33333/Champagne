//
//  GameDiscoverView.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import SwiftUI
import WhiskyKit

/// Curated Steam discovery, seeded with titles that already have a Champagne
/// compatibility profile. Steam remains responsible for account sign-in and
/// checking whether the current account can install each title.
struct GameDiscoverView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var bottleVM: BottleVM
    @State private var searchText = ""
    @State private var installing = false
    @State private var status: String?
    @State private var installError: String?

    private static let catalog = GameCatalogSeed.compatibleSteamGames(from: GameDBLoader.loadDefaults())

    private var visibleGames: [GameCatalogEntry] {
        guard !searchText.isEmpty else { return Self.catalog }
        return Self.catalog.filter { game in
            game.title.localizedCaseInsensitiveContains(searchText)
                || (game.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false)
                || game.aliases.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if visibleGames.isEmpty {
                    ContentUnavailableView(
                        "discover.empty.title",
                        systemImage: "magnifyingglass",
                        description: Text("discover.empty.description")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(visibleGames) { game in
                            gameCard(game)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("discover.title")
        .searchable(text: $searchText, prompt: Text("discover.search"))
        .accessibilityIdentifier("gameDiscoverView")
        .alert("Steam setup", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("discover.hero.title")
                .font(.largeTitle.bold())
            Text("discover.hero.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                HStack {
                    if installing { ProgressView().controlSize(.small) }
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func gameCard(_ game: GameCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                Spacer(minLength: 8)

                if let rating = game.compatibilityRating {
                    Label(rating.displayName, systemImage: rating.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let subtitle = game.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                ForEach(Array(game.installSources.enumerated()), id: \.offset) { item in
                    installButton(for: item.element)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func installButton(for source: GameInstallSource) -> some View {
        switch source {
        case let .steam(appID):
            Button {
                Task { await installSteamGame(appID) }
            } label: {
                Label("Install with Steam", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(installing)
        case let .publisherDownloadPage(url):
            Button {
                openURL(url)
            } label: {
                Label("discover.publisherPage", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
        }
    }

    @MainActor
    private func installSteamGame(_ appID: Int) async {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        let key = "champagne.managedSteamBottle"
        var bottle = UserDefaults.standard.url(forKey: key).flatMap { saved in
            bottleVM.bottles.first { $0.url.standardizedFileURL == saved.standardizedFileURL && $0.isAvailable }
        }
        if bottle == nil {
            status = "Preparing your game environment…"
            bottle = await bottleVM.createManagedBottle(
                bottleName: "Champagne Games", winVersion: .win10, bottleURL: BottleData.defaultBottleDir
            )
            guard let bottle else { status = nil; return }
            UserDefaults.standard.set(bottle.url, forKey: key)
        }
        guard let bottle else { status = nil; return }

        do {
            if SteamLibrary.detectInstall(bottleURL: bottle.url) == nil {
                status = "Downloading Steam…"
                let url = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!
                let (download, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw CocoaError(.fileReadUnknown)
                }
                let installer = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("exe")
                try FileManager.default.moveItem(at: download, to: installer)
                defer { try? FileManager.default.removeItem(at: installer) }
                status = "Complete Steam setup in the installer window."
                let result = try await Wine.runProgram(at: installer, bottle: bottle)
                guard result.exitCode == 0, SteamLibrary.detectInstall(bottleURL: bottle.url) != nil else {
                    throw NSError(domain: "ChampagneSteamSetup", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Steam setup did not complete. Please try again."
                    ])
                }
            }
            guard let root = SteamLibrary.detectInstall(bottleURL: bottle.url) else { return }
            status = "Sign in to Steam and follow its install prompt."
            let result = try await Wine.runProgram(
                at: root.appending(path: "steam.exe"), args: ["steam://install/\(appID)"], bottle: bottle
            )
            if result.exitCode != 0 {
                throw NSError(domain: "ChampagneSteamSetup", code: Int(result.exitCode), userInfo: [
                    NSLocalizedDescriptionKey: "Steam could not open the install request. Open Steam and install the game from your library."
                ])
            }
        } catch {
            status = nil
            installError = error.localizedDescription
        }
    }
}
