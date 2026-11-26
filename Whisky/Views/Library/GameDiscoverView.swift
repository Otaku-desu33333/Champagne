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
    var showLibrary: () -> Void
    @State private var searchText = ""
    @State private var installing = false
    @AppStorage("champagne.pendingSteamAppID") private var legacyPendingAppID = 0
    @AppStorage("champagne.pendingSteamAppIDs") private var pendingIDsText = ""
    @AppStorage("champagne.steamAccountName") private var steamAccountName = ""
    @State private var installProgress: [Int: SteamLibrary.InstallProgress] = [:]
    @State private var installedSteamIDs: Set<Int> = []
    @StateObject private var steamCMDSession = SteamCMDDownloadSession.shared
    @State private var accountPrompt: SteamAccountPrompt?
    @State private var authenticationPrompt: SteamCMDAuthenticationPrompt?

    private var pendingAppIDs: [Int] {
        SteamInstallRequests.decode(pendingIDsText)
    }

    private func rememberPending(_ appID: Int) {
        pendingIDsText = SteamInstallRequests.adding(appID, to: pendingIDsText)
    }

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
        .task(id: bottleVM.bottles.filter(\.isAvailable).map(\.url)) {
            while !Task.isCancelled {
                let urls = bottleVM.bottles.filter(\.isAvailable).map(\.url)
                let installed = await Task.detached {
                    Set(urls.flatMap { SteamLibrary.enumerate(bottleURL: $0).map(\.appId) })
                }.value
                guard !Task.isCancelled else { return }
                installedSteamIDs = installed
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .onAppear {
            if legacyPendingAppID > 0 {
                rememberPending(legacyPendingAppID)
                legacyPendingAppID = 0
            }
            if steamCMDSession.didComplete {
                bottleVM.steamSetupStatus = "Downloaded in Champagne. Steam may ask you to sign in the first time you play."
            }
        }
        .task(id: pendingIDsText) {
            let ids = pendingAppIDs
            installProgress = [:]
            while !ids.isEmpty && !Task.isCancelled {
                if let url = bottleVM.managedSteamBottleURL {
                    let progress = await Task.detached {
                        Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                            SteamLibrary.installProgress(appID: id, bottleURL: url).map { (id, $0) }
                        })
                    }.value
                    guard !Task.isCancelled, pendingAppIDs == ids else { return }
                    installProgress = progress
                    if ids.allSatisfy({ progress[$0]?.installed == true }) && bottleVM.steamSetupToken == nil {
                        bottleVM.steamSetupStatus = nil
                    }
                } else {
                    installProgress = [:]
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .alert("Steam setup", isPresented: Binding(
            get: { bottleVM.steamSetupError != nil || steamCMDSession.errorMessage != nil },
            set: {
                if !$0 {
                    bottleVM.steamSetupError = nil
                    steamCMDSession.dismissError()
                }
            }
        )) {
            Button("OK", role: .cancel) {
                bottleVM.steamSetupError = nil
                steamCMDSession.dismissError()
            }
        } message: {
            Text(bottleVM.steamSetupError ?? steamCMDSession.errorMessage ?? "")
        }
        .onChange(of: steamCMDSession.authenticationPrompt) { _, prompt in
            authenticationPrompt = prompt
        }
        .onChange(of: steamCMDSession.didComplete) { _, didComplete in
            guard didComplete else { return }
            bottleVM.steamSetupStatus = "Downloaded in Champagne. Steam may ask you to sign in the first time you play."
        }
        .onChange(of: steamCMDSession.errorMessage) { _, message in
            if message != nil { bottleVM.steamSetupStatus = nil }
        }
        .sheet(item: $accountPrompt) { prompt in
            SteamAccountNameSheet(initialValue: steamAccountName) { accountName in
                steamAccountName = accountName
                accountPrompt = nil
                Task { await installSteamGame(prompt.appID, title: prompt.title, accountName: accountName) }
            }
        }
        .sheet(item: $authenticationPrompt) { prompt in
            SteamCMDAuthenticationSheet(
                prompt: prompt,
                submit: { response in
                    do {
                        try steamCMDSession.submitAuthenticationResponse(response)
                        authenticationPrompt = nil
                    } catch {
                        bottleVM.steamSetupError = error.localizedDescription
                    }
                },
                cancel: {
                    steamCMDSession.cancel()
                    authenticationPrompt = nil
                }
            )
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
            let directStatus = steamCMDSession.didComplete
                ? "Downloaded in Champagne. Steam may ask you to sign in the first time you play."
                : steamCMDSession.status
            if let status = directStatus ?? bottleVM.steamSetupStatus {
                HStack {
                    if bottleVM.steamSetupToken != nil || steamCMDSession.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    Text(status).foregroundStyle(.secondary)
                    if steamCMDSession.canCancel {
                        Button("Cancel download") { steamCMDSession.cancel() }
                            .buttonStyle(.link)
                    }
                }
            }
            ForEach(pendingAppIDs, id: \.self) { appID in
                let title = Self.catalog.first { game in
                    game.installSources.contains(.steam(appID: appID))
                }?.title ?? String(appID)
                if steamCMDSession.appID == appID, steamCMDSession.isRunning,
                   let progress = steamCMDSession.progress, progress.totalBytes > 0 {
                    VStack(alignment: .leading) {
                        Text("\(title): Downloading in Champagne")
                        ProgressView(value: Double(progress.downloadedBytes), total: Double(progress.totalBytes))
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: progress.downloadedBytes), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: progress.totalBytes), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if steamCMDSession.appID == appID, steamCMDSession.isRunning {
                    Text("\(title): Preparing a direct Steam download in Champagne…")
                        .foregroundStyle(.secondary)
                } else if let progress = installProgress[appID],
                          let downloaded = progress.downloadedBytes,
                          let total = progress.totalBytes, total > 0, downloaded < total {
                    VStack(alignment: .leading) {
                        Text("\(title): Steam download")
                        ProgressView(value: Double(downloaded), total: Double(total))
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: downloaded), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let progress = installProgress[appID], progress.installed {
                    Text("\(title) is installed. Find it in your library.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(title): ready to download through Champagne after Steam checks the account.")
                        Text("If Steam cannot confirm access, Champagne will stop before adding the game to your library.")
                    }
                    .foregroundStyle(.secondary)
                }
                Button("Dismiss status") {
                    pendingIDsText = SteamInstallRequests.removing(appID, from: pendingIDsText)
                }
                .buttonStyle(.link)
                .help("This only hides the status; Steam continues any active download.")
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
                if let issue = game.compatibilityIssue, !issue.isEmpty {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                ForEach(Array(game.installSources.enumerated()), id: \.offset) { item in
                    installButton(for: item.element, title: game.title)
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
    private func installButton(for source: GameInstallSource, title: String) -> some View {
        switch source {
        case let .steam(appID):
            if installedSteamIDs.contains(appID) || installProgress[appID]?.installed == true {
                Button(action: showLibrary) {
                    Label("Open library", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if steamAccountName.isEmpty {
                        accountPrompt = SteamAccountPrompt(appID: appID, title: title)
                    } else {
                        Task { await installSteamGame(appID, title: title, accountName: steamAccountName) }
                    }
                } label: {
                    Label("Install in Champagne", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(bottleVM.steamSetupToken != nil || steamCMDSession.isRunning)
            }
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
    private func installSteamGame(_ appID: Int, title: String, accountName: String) async {
        guard !installing, bottleVM.steamSetupToken == nil, !steamCMDSession.isRunning else { return }
        let token = UUID()
        installing = true
        bottleVM.latestSteamRequest = token
        bottleVM.steamSetupToken = token
        defer {
            if bottleVM.steamSetupToken == token {
                installing = false
                bottleVM.steamSetupToken = nil
            }
        }
        var savedURL = bottleVM.managedSteamBottleURL
        if let saved = savedURL, bottleVM.bottlesList.canDiscardUncreatedReservation(saved) {
            // A restart may have happened before creation made the directory.
            // Only clear a reservation that has neither files nor a registry entry.
            bottleVM.forgetManagedSteamBottle()
            savedURL = nil
        }
        var bottle = savedURL.flatMap { saved in
            bottleVM.bottles.first { $0.url.standardizedFileURL == saved.standardizedFileURL && $0.isAvailable }
        }
        if savedURL != nil && bottle == nil {
            bottleVM.steamSetupError = "Your Champagne game environment could not be found. Restore or re-import it before installing another game."
            return
        }
        if bottle == nil {
            bottleVM.steamSetupStatus = "Preparing your game environment…"
            bottle = await bottleVM.createManagedBottle(
                bottleName: "Champagne Games", winVersion: .win10, bottleURL: BottleData.defaultBottleDir
            )
            guard bottle != nil else { bottleVM.steamSetupStatus = nil; return }
        }
        guard let bottle else { bottleVM.steamSetupStatus = nil; return }

        do {
            // This environment is dedicated to Steam. Apply the same launcher
            // profile used by the existing Steam orchestrator before either
            // the installer or the client starts.
            if bottle.settings.launcherMode == .auto && bottle.settings.detectedLauncher != .steam {
                LauncherFixes.apply(to: bottle, launcher: .steam)
            }
            let setupMarker = SteamSetupMarker()
            if setupMarker.needsSetup(clientExists: SteamLibrary.detectInstall(bottleURL: bottle.url) != nil) {
                // Persist before starting: the installer can create steam.exe
                // before it finishes, so its presence alone is not completion.
                setupMarker.begin()
                bottleVM.steamSetupStatus = "Downloading Steam…"
                let url = URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!
                let (download, response) = try await URLSession.shared.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme?.lowercased() == "https",
                      http.url?.host?.lowercased() == "cdn.fastly.steamstatic.com" else {
                    throw NSError(domain: "ChampagneSteamSetup", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Steam could not be downloaded. Check your connection and try again."
                    ])
                }
                let handle = try FileHandle(forReadingFrom: download)
                let signature = try handle.read(upToCount: 2)
                try handle.close()
                guard signature == Data([0x4d, 0x5a]) else {
                    throw NSError(domain: "ChampagneSteamSetup", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "The Steam download was not a Windows installer. Please try again."
                    ])
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let installer = directory.appendingPathComponent("SteamSetup.exe")
                try FileManager.default.moveItem(at: download, to: installer)
                bottleVM.steamSetupStatus = "Setting up Steam…"
                // SteamSetup is an NSIS installer. Its silent switch keeps
                // environment preparation inside the Install action instead
                // of opening a separate wizard for the user to complete.
                let result = try await Wine.runProgram(
                    at: installer, args: ["/S"], bottle: bottle, waitForExit: true
                )
                guard result.exitCode == 0, SteamLibrary.detectInstall(bottleURL: bottle.url) != nil else {
                    throw NSError(domain: "ChampagneSteamSetup", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Steam setup did not complete. Please try again."
                    ])
                }
                setupMarker.complete()
            }
            guard SteamLibrary.detectInstall(bottleURL: bottle.url) != nil else {
                throw NSError(domain: "ChampagneSteamSetup", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Steam could not be found. Please try setup again."
                ])
            }
            rememberPending(appID)
            bottleVM.steamSetupStatus = "Starting the direct Champagne download…"
            try await steamCMDSession.start(
                appID: appID, title: title, accountName: accountName, bottleURL: bottle.url
            )
        } catch {
            // A later request may already be in progress after this launch
            // started. Do not overwrite its status with an older result.
            if bottleVM.latestSteamRequest == token {
                steamCMDSession.clearFailedStart()
                bottleVM.steamSetupStatus = nil
                bottleVM.steamSetupError = error.localizedDescription
            }
        }
    }
}

private struct SteamAccountPrompt: Identifiable {
    let appID: Int
    let title: String
    var id: Int { appID }
}

private struct SteamAccountNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var accountName: String
    let onContinue: (String) -> Void

    init(initialValue: String, onContinue: @escaping (String) -> Void) {
        _accountName = State(initialValue: initialValue)
        self.onContinue = onContinue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to Steam")
                .font(.title2.bold())
            Text("Sign in to Steam so Champagne can check access and download the Windows game files. Your password and verification code are requested securely if Steam needs them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Steam account name", text: $accountName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(continueIfValid)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Continue", action: continueIfValid)
                    .buttonStyle(.borderedProminent)
                    .disabled(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func continueIfValid() {
        let value = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onContinue(value)
    }
}

private struct SteamCMDAuthenticationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var response = ""
    let prompt: SteamCMDAuthenticationPrompt
    let submit: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt == .password ? "Steam password" : "Steam verification code")
                .font(.title2.bold())
            Text(prompt == .password
                 ? "Your password is sent directly to SteamCMD through a private input stream. Champagne does not save it."
                 : "Enter the email or authenticator code Steam requested. Champagne does not save the code.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if prompt == .password {
                    SecureField("Password", text: $response)
                } else {
                    TextField("Verification code", text: $response)
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(submitResponse)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    cancel()
                    dismiss()
                }
                Button("Continue", action: submitResponse)
                    .buttonStyle(.borderedProminent)
                    .disabled(response.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }

    private func submitResponse() {
        guard !response.isEmpty else { return }
        submit(response)
        response = ""
        dismiss()
    }
}
