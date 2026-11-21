//
//  WineRuntimeStoreTests.swift
//  WhiskyKit
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
import SemanticVersion
import Testing
@testable import WhiskyKit

struct WineRuntimeStoreTests {
    @Test("A complete named runtime is published in its isolated runtime root")
    func installsCompleteRuntime() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let runtimeRoot = temp.appending(path: "Runtimes")
        let archive = try makeRuntimeArchive(in: temp)
        let digest = try #require(WhiskyWineInstaller.sha256(ofFileAt: archive))

        let runtime = try WineRuntimeStore.install(
            tarball: archive,
            identifier: "wine-test",
            expectedSHA256: digest,
            inRuntimesDirectory: runtimeRoot
        )

        #expect(runtime.identifier == "wine-test")
        #expect(runtime.versionInfo.version == SemanticVersion(4, 0, 0))
        #expect(FileManager.default.isExecutableFile(
            atPath: runtime.libraryFolder.appending(path: "Wine/bin/wine64").path(percentEncoded: false)
        ))
        #expect(try FileManager.default.contentsOfDirectory(atPath: runtimeRoot.path) == ["wine-test"])
        #expect(WineRuntimeStore.installedNamedRuntimes(inRuntimesDirectory: runtimeRoot).map(\.identifier)
            == ["wine-test"])
    }

    @Test("An incomplete runtime archive leaves no published or staging directory")
    func incompleteArchiveIsDiscarded() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let runtimeRoot = temp.appending(path: "Runtimes")
        let archive = try makeRuntimeArchive(in: temp, complete: false)

        #expect(throws: WineRuntimeStoreError.archiveDoesNotContainRuntime) {
            try WineRuntimeStore.install(
                tarball: archive,
                identifier: "wine-incomplete",
                inRuntimesDirectory: runtimeRoot
            )
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: runtimeRoot.path).isEmpty)
        #expect(WineRuntimeStore.installedNamedRuntimes(inRuntimesDirectory: runtimeRoot).isEmpty)
    }

    @Test("Named runtime discovery ignores partial and symbolic-link entries")
    func discoveryIgnoresPartialAndSymbolicLinkEntries() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let runtimeRoot = temp.appending(path: "Runtimes")
        let linkedTarget = temp.appending(path: "linked-target")
        let valid = runtimeRoot.appending(path: "wine-valid")
        let partial = runtimeRoot.appending(path: "wine-partial")
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try makeCompleteRuntime(at: valid)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try makeCompleteRuntime(at: linkedTarget)
        try FileManager.default.createSymbolicLink(
            at: runtimeRoot.appending(path: "wine-linked"),
            withDestinationURL: linkedTarget
        )

        let discovered = WineRuntimeStore.installedNamedRuntimes(inRuntimesDirectory: runtimeRoot)
        #expect(discovered.map(\.identifier) == ["wine-valid"])

        let linkedRoot = temp.appending(path: "Runtimes-link")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: runtimeRoot)
        #expect(WineRuntimeStore.installedNamedRuntimes(inRuntimesDirectory: linkedRoot).isEmpty)
    }

    @Test("An existing incomplete identifier is occupied before catalog download")
    func incompleteIdentifierIsOccupied() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let runtimeRoot = temp.appending(path: "Runtimes")
        try FileManager.default.createDirectory(
            at: runtimeRoot.appending(path: "wine-partial"),
            withIntermediateDirectories: true
        )

        #expect(WineRuntimeStore.isIdentifierOccupied("wine-partial", inRuntimesDirectory: runtimeRoot))
        #expect(!WineRuntimeStore.isIdentifierOccupied("wine-new", inRuntimesDirectory: runtimeRoot))
        #expect(WineRuntimeStore.isIdentifierOccupied("../unsafe", inRuntimesDirectory: runtimeRoot))
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "runtime-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRuntimeArchive(in directory: URL, complete: Bool = true) throws -> URL {
        let sourceRoot = directory.appending(path: "source")
        let libraries = sourceRoot.appending(path: "Libraries")
        try makeCompleteRuntime(at: libraries, complete: complete)

        let archive = directory.appending(path: "runtime.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.currentDirectoryURL = sourceRoot
        tar.arguments = ["-czf", archive.path(percentEncoded: false), "Libraries"]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return archive
    }

    private func makeCompleteRuntime(at libraryFolder: URL, complete: Bool = true) throws {
        let fileManager = FileManager.default
        let wineBin = libraryFolder.appending(path: "Wine/bin")
        try fileManager.createDirectory(at: wineBin, withIntermediateDirectories: true)
        for name in ["wine64", "wineserver"] {
            let binary = wineBin.appending(path: name)
            try Data("test \(name)".utf8).write(to: binary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path(percentEncoded: false))
        }

        let version: [String: Any] = ["version": ["major": 4, "minor": 0, "patch": 0]]
        let plist = try PropertyListSerialization.data(fromPropertyList: version, format: .xml, options: 0)
        try plist.write(to: libraryFolder.appending(path: "WhiskyWineVersion.plist"))

        guard complete else { return }
        for architecture in ["x64", "x32"] {
            let directory = libraryFolder.appending(path: "DXVK").appending(path: architecture)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("test dxvk".utf8).write(to: directory.appending(path: "d3d11.dll"))
        }
    }
}
