//
//  GPTKDeploymentSafetyTests.swift
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
import SemanticVersion
import Testing
@testable import WhiskyKit

@Suite("GPTK Deployment Safety Tests")
struct GPTKDeploymentSafetyTests {
    private let tempDir: URL

    init() throws {
        tempDir = try makeGPTKTempDir()
    }

    @Test("Concurrent GPTK file operations serialize")
    func fileOperationsSerialize() {
        let probe = GPTKOperationProbe()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            GPTKImporter.withFileOperationLock {
                probe.begin()
                Thread.sleep(forTimeInterval: 0.005)
                probe.end()
            }
        }

        #expect(probe.maximumConcurrentWork == 1)
    }

    @Test("Same numeric Wine versions with different runtime builds never share GPTK backups")
    func buildFingerprintDistinguishesSameVersionBuilds() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime, marker: "wine beta one")
        try writeRuntimeVersion(at: runtime, 4, 0, 0)
        let firstStamp = try #require(GPTKImporter.runtimeVersionStamp(inLibraryFolder: runtime))
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        // Models beta.1 -> beta.2 archives whose plist keeps the same
        // major.minor.patch but whose Wine binaries differ.
        try makeRuntime(at: runtime, marker: "wine beta two")
        try writeRuntimeVersion(at: runtime, 4, 0, 0)
        let secondStamp = try #require(GPTKImporter.runtimeVersionStamp(inLibraryFolder: runtime))
        #expect(firstStamp != secondStamp)

        try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: store)

        let current = runtime.appending(path: "Wine/lib/wine/x86_64-windows/d3d11.dll")
        #expect(try Data(contentsOf: current).suffix(13) == Data("wine beta two".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: store.appending(path: "originals/d3d11.dll").path(percentEncoded: false)
        ))
    }

    @Test("Unverifiable legacy backups are retained and removal fails safely")
    func removalKeepsAmbiguousLegacyBackups() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(GPTKOriginalsRecord(runtimeVersion: "4.0.0"))
            .write(to: GPTKImporter.originalsRecordURL(inOriginalsFolder: store.appending(path: "originals")))

        #expect(throws: GPTKImportError.runtimeOriginalsUnverified("Libraries")) {
            try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: store)
        }

        #expect(FileManager.default.fileExists(
            atPath: store.appending(path: "originals/d3d11.dll").path(percentEncoded: false)
        ))
        #expect(GPTKImporter.isDeployed(inLibraryFolder: runtime))
    }

    @Test("A missing runtime version plist does not make nil backup stamps match")
    func removalRejectsMissingRuntimeStamp() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)
        try FileManager.default.removeItem(
            at: runtime.appending(path: "WhiskyWineVersion.plist")
        )

        #expect(throws: GPTKImportError.runtimeOriginalsUnverified("Libraries")) {
            try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: store)
        }
        #expect(FileManager.default.fileExists(
            atPath: store.appending(path: "originals/d3d11.dll").path(percentEncoded: false)
        ))
        #expect(GPTKImporter.isDeployed(inLibraryFolder: runtime))
    }

    @Test("Removing another store leaves a hand-placed GPTK tree untouched")
    func removeLeavesHandPlacedPayload() throws {
        let runtime = tempDir.appending(path: "Libraries")
        let deployedStore = try makeImportedStore(in: tempDir.appending(path: "deployed"))
        let unrelatedStore = try makeImportedStore(in: tempDir.appending(path: "unrelated"))
        try Data("different forwarder".utf8).write(
            to: unrelatedStore.appending(path: "lib/wine/x86_64-windows/d3d11.dll")
        )
        try makeRuntime(at: runtime)
        try GPTKImporter.deploy(fromStore: deployedStore, intoLibraryFolder: runtime)

        try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: unrelatedStore)

        #expect(GPTKImporter.isDeployed(inLibraryFolder: runtime))
        let bridge = runtime.appending(path: "Wine/lib/external/libd3dshared.dylib")
        #expect(FileManager.default.fileExists(atPath: bridge.path(percentEncoded: false)))
        let unix = runtime.appending(path: "Wine/lib/wine/x86_64-unix/dxgi.so")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: unix.path) == GPTKImporter
            .unixLinkDestination)
    }

    @Test("Removing the store cleans matching fragments from an incomplete named runtime")
    func removingStoreCleansPartialNamedRuntime() throws {
        let store = try makeImportedStore(in: tempDir)
        let defaultRuntime = tempDir.appending(path: "DefaultLibraries")
        let runtimeRoot = tempDir.appending(path: "Runtimes")
        let runtimeFolder = runtimeRoot.appending(path: "wine-partial")
        try makeRuntime(at: runtimeFolder)

        let storeForwarder = store.appending(path: "lib").appending(path: "wine")
            .appending(path: "x86_64-windows").appending(path: "d3d11.dll")
        let runtimeForwarder = runtimeFolder.appending(path: "Wine").appending(path: "lib")
            .appending(path: "wine").appending(path: "x86_64-windows").appending(path: "d3d11.dll")
        try FileManager.default.removeItem(at: runtimeForwarder)
        try FileManager.default.copyItem(at: storeForwarder, to: runtimeForwarder)

        let namedRuntimes = try GPTKImporter.namedRuntimeFoldersOnDisk(at: runtimeRoot)
        #expect(namedRuntimes.map(\.identifier) == ["wine-partial"])
        try GPTKImporter.removeDeployedPayloads(
            fromDefaultRuntime: defaultRuntime,
            namedRuntimeFolders: namedRuntimes,
            usingStore: store
        )

        #expect(!FileManager.default.fileExists(atPath: runtimeForwarder.path))
        #expect(FileManager.default.fileExists(
            atPath: runtimeFolder.appending(path: "Wine").appending(path: "lib").appending(path: "wine")
                .appending(path: "x86_64-windows").appending(path: "d3d10.dll").path
        ))
    }

    @Test("Deploy and removal preserve unrelated files under Wine lib external")
    func deploymentPreservesUnrelatedExternalFiles() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        let external = runtime.appending(path: "Wine/lib/external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let unrelated = external.appending(path: "host-provider.dylib")
        try Data("owned by Wine".utf8).write(to: unrelated)

        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)
        #expect(try Data(contentsOf: unrelated) == Data("owned by Wine".utf8))
        try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: store)

        #expect(try Data(contentsOf: unrelated) == Data("owned by Wine".utf8))
    }

    @Test("Reimport redeploys GPTK to every previously managed capable runtime")
    func reimportRestoresNamedRuntimeDeployments() throws {
        let store = try makeImportedStore(in: tempDir)
        let installed = try installNamedRuntimes(inStore: store)
        let targets = GPTKImporter.deployedRuntimes(from: installed, usingStore: store)
        #expect(targets.map(\.identifier).sorted() == ["runtime-a", "runtime-b"])
        try reimportUpdatedPayload(inStore: store, to: targets)

        #expect(GPTKImporter.storedRecord(inStore: store)?.gptkVersion == "4.1.0")
        #expect(installed.allSatisfy {
            GPTKImporter.isStorePayloadDeployed(inLibraryFolder: $0.libraryFolder, usingStore: store)
        })
        expectWineBackups(for: installed, inStore: store)
    }

    private func installNamedRuntimes(inStore store: URL) throws -> [InstalledWineRuntime] {
        let runtimeInfo = WhiskyWineVersion(version: SemanticVersion(4, 0, 0), gptkCapable: true)
        let installed = ["runtime-a", "runtime-b"].map { identifier in
            let runtimeFolder = tempDir.appending(path: "Runtimes/\(identifier)")
            return InstalledWineRuntime(identifier: identifier, libraryFolder: runtimeFolder, versionInfo: runtimeInfo)
        }
        for (runtime, marker) in zip(installed, ["Wine A original", "Wine B original"]) {
            try makeRuntime(at: runtime.libraryFolder, marker: marker)
            try deploy(runtime, fromStore: store)
        }
        return installed
    }

    private func reimportUpdatedPayload(inStore store: URL, to targets: [InstalledWineRuntime]) throws {
        let payloadRoot = tempDir.appending(path: "updated-payload")
        try makePayload(at: payloadRoot, version: "4.1.0")
        let payload = try GPTKImporter.validatePayload(at: payloadRoot, isAppleSigned: { _, _ in true })
        let beforeReplacement: () throws -> Void = { try self.removeDeployments(for: targets, inStore: store) }
        let afterReplacement: (GPTKStoreRecord) throws -> Void = { _ in
            try self.redeployPayload(to: targets, fromStore: store)
        }
        _ = try GPTKImporter.importPayload(
            payload,
            intoStore: store,
            revalidatingWith: { _, _ in true },
            beforeReplacingStoredPayload: beforeReplacement,
            afterReplacingStoredPayload: afterReplacement
        )
    }

    private func removeDeployments(for runtimes: [InstalledWineRuntime], inStore store: URL) throws {
        for runtime in runtimes {
            try GPTKImporter.remove(
                fromLibraryFolder: runtime.libraryFolder,
                usingStore: store,
                originalsFolder: GPTKImporter.originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
            )
        }
    }

    private func redeployPayload(to targets: [InstalledWineRuntime], fromStore store: URL) throws {
        try GPTKImporter.redeployStoredPayloads(to: targets, usingStore: store) { runtime in
            try deploy(runtime, fromStore: store)
        }
    }

    private func deploy(_ runtime: InstalledWineRuntime, fromStore store: URL) throws {
        try GPTKImporter.deploy(
            fromStore: store,
            intoLibraryFolder: runtime.libraryFolder,
            originalsFolder: GPTKImporter.originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
        )
    }

    private func expectWineBackups(for runtimes: [InstalledWineRuntime], inStore store: URL) {
        for runtime in runtimes {
            let backup = GPTKImporter.originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
                .appending(path: "d3d11.dll")
            let marker = Data("Wine \(runtime.identifier.suffix(1).uppercased()) original".utf8)
            #expect((try? Data(contentsOf: backup).suffix(marker.count)) == marker)
        }
    }
}

private final class GPTKOperationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumConcurrentWork: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func begin() {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
    }

    func end() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}
