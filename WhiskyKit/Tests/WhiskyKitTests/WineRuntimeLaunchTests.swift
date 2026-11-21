//
//  WineRuntimeLaunchTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite("Wine runtime launch")
@MainActor
final class WineRuntimeLaunchTests {
    private let tempRoot: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "wine_runtime_launch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeBottle() throws -> Bottle {
        let bottleURL = tempRoot.appending(path: "Bottle")
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true
        )
        return Bottle(bottleUrl: bottleURL)
    }

    private func makeExecutable(in bottle: Bottle) throws -> URL {
        let executable = bottle.url.appending(path: "drive_c/Games/Game.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("MZ".utf8).write(to: executable)
        return executable
    }

    @Test("An unavailable saved backend falls back for this launch without changing the bottle")
    func unavailableBackendFallsBackForLaunch() async throws {
        let bottle = try makeBottle()
        bottle.settings.graphicsBackend = .dxmt
        let executable = try makeExecutable(in: bottle)
        var programOverrides: [String: String]?
        let overrideWriter: Wine.DLLOverrideWriter = { _, scopes in
            guard let programScope = scopes.first(where: { $0.scope == .program("Game.exe") }) else { return }
            programOverrides = Wine.parseDLLOverrides(programScope.overrides)
        }

        let launch = try await Wine.prepareProgramLaunch(
            at: executable,
            bottle: bottle,
            recommendedBackend: .wined3d,
            builtinD3D12IsD3DMetal: false,
            backendAvailability: { $0 == .wined3d },
            overrideWriter: overrideWriter,
            importer: { _, _ in }
        )

        #expect(bottle.settings.graphicsBackend == .dxmt)
        #expect(launch.environment["WINED3DMETAL"] == "0")
        #expect(launch.wineBinary == Wine.wineBinary)
        #expect(programOverrides?["d3d11"] == "b")
    }

    @Test("A prepared terminal command keeps the runtime executable captured at preparation")
    func preparedCommandUsesCapturedRuntime() throws {
        let bottle = try makeBottle()
        let selectedBinary = tempRoot.appending(path: "Runtimes/wine-4.8.3/Wine/bin/wine64")
        let launch = Wine.PreparedLaunch(
            environment: ["WINEPREFIX": bottle.url.path],
            arguments: ["start", "/unix", bottle.url.appending(path: "Game.exe").path],
            wineBinary: selectedBinary
        )

        let command = Wine.generateRunCommand(for: launch, bottle: bottle)

        #expect(command.contains(selectedBinary.path.esc))
        #expect(!command.contains(Wine.wineBinary.path.esc))
    }
}
