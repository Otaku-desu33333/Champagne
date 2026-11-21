//
//  WineRuntimeCatalogSheet.swift
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

import SwiftUI
import WhiskyKit

struct WineRuntimeCatalogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var releases: [WineRuntimeCatalogRelease] = []
    @State private var isLoading = true
    @State private var loadingError: String?
    @State private var installingTag: String?
    @State private var installProgress: Double?
    @State private var installError: String?
    @State private var installTask: Task<Void, Never>?

    let onInstalled: (WineRuntimeCatalogRelease, String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("runtime.catalog.description")
                    if let sourceURL = URL(string: "https://github.com/frankea/Whisky/releases") {
                        Link("runtime.catalog.source", destination: sourceURL)
                    }
                    if let champagneSourceURL = URL(string: "https://github.com/Otaku-desu33333/Champagne/releases") {
                        Link("runtime.catalog.champagneSource", destination: champagneSourceURL)
                    }
                }

                if isLoading {
                    Section {
                        ProgressView("runtime.catalog.loading")
                    }
                } else if let loadingError {
                    Section {
                        Text(loadingError)
                            .foregroundStyle(.red)
                    }
                } else if releases.isEmpty {
                    Section {
                        Text("runtime.catalog.empty")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(releases) { release in
                        releaseRow(release)
                    }
                }
            }
            .navigationTitle("runtime.catalog.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("button.done") { dismiss() }
                }
            }
            .task { await loadReleases() }
            .onDisappear {
                installTask?.cancel()
            }
            .alert(
                "runtime.catalog.installError.title",
                isPresented: Binding(
                    get: { installError != nil },
                    set: { if !$0 { installError = nil } }
                )
            ) {
                Button("button.ok", role: .cancel) {}
            } message: {
                Text(installError ?? "")
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder
    private func releaseRow(_ release: WineRuntimeCatalogRelease) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.title)
                    .font(.headline)
                Spacer(minLength: 8)
                if release.isPrerelease {
                    Text("runtime.catalog.prerelease")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Text(release.repository)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("runtime.catalog.shaVerified")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Link("runtime.catalog.releaseNotes", destination: release.releaseURL)
                Spacer()
                if installingTag == release.id {
                    if let installProgress {
                        ProgressView(value: installProgress)
                            .controlSize(.small)
                            .frame(width: 80)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("runtime.catalog.downloading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("runtime.catalog.install") {
                        install(release)
                    }
                    .disabled(installingTag != nil)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func loadReleases() async {
        do {
            releases = try await WineRuntimeCatalog.releases()
            loadingError = nil
        } catch {
            loadingError = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func install(_ release: WineRuntimeCatalogRelease) {
        let identifier = nextIdentifier(for: release)
        installingTag = release.id
        installProgress = nil
        installError = nil
        installTask = Task { @MainActor in
            defer {
                installingTag = nil
                installTask = nil
            }
            do {
                _ = try await WineRuntimeCatalog.install(release, identifier: identifier) { progress in
                    guard let expectedBytes = progress.expectedBytes, expectedBytes > 0 else { return }
                    let fraction = min(1, Double(progress.bytesOnDisk) / Double(expectedBytes))
                    Task { @MainActor in installProgress = fraction }
                }
                onInstalled(release, identifier)
                dismiss()
            } catch is CancellationError {
                // The resumable download keeps its partial archive for the next attempt.
            } catch {
                installError = error.localizedDescription
            }
        }
    }

    private func nextIdentifier(for release: WineRuntimeCatalogRelease) -> String {
        let base = release.suggestedIdentifier
        var identifier = base
        var suffix = 2
        while WineRuntimeStore.isIdentifierOccupied(identifier) {
            let suffixText = "-\(suffix)"
            let prefix = String(base.prefix(max(1, 64 - suffixText.count)))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
            identifier = "\(prefix)\(suffixText)"
            suffix += 1
        }
        return identifier
    }
}
