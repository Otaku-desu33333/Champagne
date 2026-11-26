//
//  ContentView+Sidebar.swift
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

import AppKit
import SemanticVersion
import SwiftUI
import WhiskyKit

// MARK: - Sidebar & Detail

extension ContentView {
    var sidebar: some View {
        ScrollViewReader { proxy in
            List(selection: $selected) {
                Section {
                    discoverRow
                    libraryRow
                }
                // A bottle is a Wine prefix, so it belongs under a heading rather
                // than being the whole sidebar. With one bottle this is the row
                // that reaches its config; with several it is also the switcher.
                if !sortedBottles.isEmpty {
                    Section("sidebar.bottles") {
                        ForEach(sortedBottles) { bottle in
                            Group {
                                if bottle.inFlight {
                                    HStack {
                                        Text(bottle.settings.name)
                                        Spacer()
                                        ProgressView().controlSize(.small)
                                    }
                                    .opacity(0.5)
                                } else if !bottle.isAvailable {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                            .font(.caption)
                                        Text(bottle.settings.name)
                                        Spacer()
                                        Button {
                                            Task { await bottle.remove(delete: false) }
                                        } label: {
                                            Image(systemName: "xmark.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("button.removeFromList.help")
                                    }
                                    .opacity(0.6)
                                    .selectionDisabled(true)
                                } else {
                                    BottleListEntry(
                                        bottle: bottle,
                                        selected: $selected,
                                        refresh: $triggerRefresh,
                                        toast: $toast
                                    )
                                    .accessibilityIdentifier("sidebar.bottle")
                                }
                            }
                            .id(bottle.url)
                        }
                    }
                }
            }
            .animation(.default, value: bottleVM.bottles)
            .listStyle(.sidebar)
            .accessibilityIdentifier("bottleSidebar")
            // No search field here. The library has one, and two fields forty
            // points apart searching different things (bottles here, programs
            // there) is a choice nobody should have to make to find a game.
            .onChange(of: newlyCreatedBottleURL) { _, url in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    selected = url
                    withAnimation {
                        proxy.scrollTo(url, anchor: .center)
                    }
                }
            }
        }
    }

    /// The library stays a separate page while discovery becomes the landing
    /// page for the Steam-first workflow.
    var libraryRow: some View {
        Button {
            selected = nil
            selectedPage = .library
        } label: {
            Label("library.title", systemImage: "square.grid.2x2")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected == nil && selectedPage == .library
                    ? AnyShapeStyle(.selection)
                    : AnyShapeStyle(.clear))
        )
        .accessibilityIdentifier("sidebar.library")
    }

    var discoverRow: some View {
        Button {
            selected = nil
            selectedPage = .discover
        } label: {
            Label("discover.title", systemImage: "sparkles")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected == nil && selectedPage == .discover
                    ? AnyShapeStyle(.selection)
                    : AnyShapeStyle(.clear))
        )
        .accessibilityIdentifier("sidebar.discover")
    }

    @ViewBuilder
    var detail: some View {
        if let selected, let bottle = bottleVM.bottles.first(where: { $0.url == selected }) {
            BottleView(bottle: bottle)
                .disabled(bottle.inFlight)
                .id(bottle.url)
        } else if selectedPage == .discover {
            GameDiscoverView()
        } else if selectedPage == .library || bottleVM.countActive() > 0 {
            LibraryView(selectedBottle: $selected, refresh: $triggerRefresh)
        } else {
            if bottleVM.bottles.isEmpty || bottleVM.countActive() == 0, bottlesLoaded {
                VStack {
                    Text("main.createFirst")
                    Button {
                        showBottleCreation.toggle()
                    } label: {
                        HStack {
                            Image(systemName: "plus")
                            Text("button.createBottle")
                        }
                        .padding(6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                }
            }
        }
    }

    var sortedBottles: [Bottle] {
        let managed = bottleVM.managedSteamBottleURL?.standardizedFileURL
        return bottleVM.bottles.filter { $0.url.standardizedFileURL != managed }.sorted()
    }
}

// MARK: - Process Close Confirmation

extension ContentView {
    @MainActor
    func showProcessCloseAlert(for bottle: Bottle) {
        let checkbox = NSButton(
            checkboxWithTitle: String(localized: "bottle.close.remember"),
            target: nil,
            action: nil
        )
        let alert = NSAlert()
        alert.messageText = String(localized: "bottle.close.confirm.title")
        alert.informativeText = String(localized: "bottle.close.confirm.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "bottle.close.keepRunning"))
        let stopButton = alert.addButton(withTitle: String(localized: "bottle.close.stopBottle"))
        stopButton.hasDestructiveAction = true
        alert.accessoryView = checkbox

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Keep Running (default)
            if checkbox.state == .on {
                bottle.settings.closeWithProcessesPolicy = .alwaysKeepRunning
            }
        } else if response == .alertSecondButtonReturn {
            // Stop Bottle
            if checkbox.state == .on {
                bottle.settings.closeWithProcessesPolicy = .alwaysStop
            }
            Wine.killBottle(bottle: bottle)
            ProcessRegistry.shared.clearRegistry(for: bottle.url)
        }
    }
}

#Preview {
    ContentView(showSetup: .constant(false))
        .environmentObject(BottleVM.shared)
}
