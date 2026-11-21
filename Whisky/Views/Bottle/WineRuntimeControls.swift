//
//  WineRuntimeControls.swift
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

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

extension WineConfigSection {
    var wineRuntimeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("runtime.selection.title")
                Spacer()
                Picker("runtime.selection.title", selection: runtimeSelection) {
                    ForEach(availableWineRuntimes) { runtime in
                        Text(runtimeLabel(runtime)).tag(runtime.identifier)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(bottle.inFlight || importingWineRuntime || selectingWineRuntime || availableWineRuntimes.isEmpty)
            }

            if let selected = availableWineRuntimes.first(where: { $0.identifier == selectedRuntimeIdentifier }) {
                let version = selected.versionInfo.version
                let capability = selected.versionInfo.gptkCapable == true
                    ? String(localized: "runtime.selection.gptkCapable")
                    : String(localized: "runtime.selection.gptkUnavailable")
                Text(String.localizedStringWithFormat(
                    String(localized: "runtime.selection.version"),
                    "\(version.major).\(version.minor).\(version.patch)",
                    capability
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("runtime.selection.missing")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button("runtime.selection.importArchive") {
                    showingWineRuntimeImporter = true
                }
                .disabled(importingWineRuntime)

                Button("runtime.catalog.browse") {
                    showingWineRuntimeCatalog = true
                }
                .disabled(importingWineRuntime)

                if importingWineRuntime || deployingGPTKToRuntime {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let selected = availableWineRuntimes.first(where: { $0.identifier == selectedRuntimeIdentifier }),
               selected.versionInfo.gptkCapable == true,
               GPTKImporter.storedRecord() != nil,
               !GPTKImporter.isDeployed(for: bottle) {
                Button("runtime.selection.deployGPTK") {
                    deployGPTKToSelectedRuntime()
                }
                .disabled(importingWineRuntime || deployingGPTKToRuntime || selectingWineRuntime)
            }

            if let wineRuntimeNotice {
                Text(wineRuntimeNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedRuntimeIdentifier: String {
        bottle.settings.wineRuntimeIdentifier ?? WineRuntimeStore.defaultRuntimeIdentifier
    }

    private var runtimeSelection: Binding<String> {
        Binding(
            get: { selectedRuntimeIdentifier },
            set: { selectWineRuntime($0) }
        )
    }

    private func runtimeLabel(_ runtime: InstalledWineRuntime) -> String {
        let version = runtime.versionInfo.version
        let name = runtime.identifier == WineRuntimeStore.defaultRuntimeIdentifier
            ? String(localized: "runtime.selection.default")
            : runtime.identifier
        return String.localizedStringWithFormat(
            String(localized: "runtime.selection.pickerLabel"),
            name,
            "\(version.major).\(version.minor).\(version.patch)"
        )
    }

    func refreshWineRuntimes() {
        availableWineRuntimes = WineRuntimeStore.installedRuntimes()
    }

    private func selectWineRuntime(_ identifier: String) {
        guard identifier != selectedRuntimeIdentifier else { return }
        selectingWineRuntime = true
        Task { @MainActor in
            defer { selectingWineRuntime = false }
            guard await !(Wine.isWineserverRunning(for: bottle)) else {
                wineRuntimeError = String(localized: "runtime.selection.closeBottleBeforeChange")
                return
            }
            do {
                try WineRuntimeStore.select(identifier, for: bottle)
                let version = bottle.settings.wineVersion
                wineRuntimeNotice = String.localizedStringWithFormat(
                    String(localized: "runtime.selection.changedNotice"),
                    version.description
                )
            } catch {
                wineRuntimeError = error.localizedDescription
            }
        }
    }

    func installWineRuntime(from url: URL) {
        let identifier = nextRuntimeIdentifier(for: url)
        importingWineRuntime = true
        wineRuntimeNotice = nil

        Task { @MainActor in
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    return try WineRuntimeStore.install(tarball: url, identifier: identifier).identifier
                }.value
                refreshWineRuntimes()
                wineRuntimeNotice = String.localizedStringWithFormat(
                    String(localized: "runtime.selection.importedNotice"),
                    identifier
                )
            } catch {
                wineRuntimeError = error.localizedDescription
            }
            importingWineRuntime = false
        }
    }

    private func deployGPTKToSelectedRuntime() {
        let identifier = selectedRuntimeIdentifier
        deployingGPTKToRuntime = true
        Task { @MainActor in
            defer { deployingGPTKToRuntime = false }
            guard await !anyBottleUsingRuntimeIsRunning(identifier) else {
                wineRuntimeError = String(localized: "runtime.selection.closeAllBottlesBeforeDeploy")
                return
            }
            do {
                try await Task.detached(priority: .utility) {
                    try GPTKImporter.deployStoredPayload(forRuntime: identifier)
                }.value
                wineRuntimeNotice = String.localizedStringWithFormat(
                    String(localized: "runtime.selection.deploySuccess"),
                    identifier
                )
            } catch {
                wineRuntimeError = error.localizedDescription
            }
        }
    }

    private func anyBottleUsingRuntimeIsRunning(_ identifier: String) async -> Bool {
        let bottles = BottleVM.shared.bottles.filter {
            ($0.settings.wineRuntimeIdentifier ?? WineRuntimeStore.defaultRuntimeIdentifier) == identifier
        }
        for candidate in bottles where await Wine.isWineserverRunning(for: candidate) {
            return true
        }
        return false
    }

    private func nextRuntimeIdentifier(for archiveURL: URL) -> String {
        var name = archiveURL.lastPathComponent.lowercased()
        for suffix in [".tar.gz", ".tgz", ".gz"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        var identifier = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        while identifier.contains("--") {
            identifier = identifier.replacingOccurrences(of: "--", with: "-")
        }
        while identifier.contains("..") {
            identifier = identifier.replacingOccurrences(of: "..", with: ".")
        }
        identifier = identifier.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        if identifier.isEmpty || identifier == WineRuntimeStore.defaultRuntimeIdentifier {
            identifier = "runtime"
        }
        if identifier.count > 56 {
            identifier = String(identifier.prefix(56)).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        }

        let installed = Set(availableWineRuntimes.map(\.identifier))
        let base = identifier
        var index = 2
        while installed.contains(identifier) || identifier == WineRuntimeStore.defaultRuntimeIdentifier {
            identifier = "\(base)-\(index)"
            index += 1
        }
        return identifier
    }
}
