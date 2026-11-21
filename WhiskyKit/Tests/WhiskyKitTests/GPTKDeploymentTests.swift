//
//  GPTKDeploymentTests.swift
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

@Suite("GPTK Deployment Tests")
struct GPTKDeploymentTests {
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

    // MARK: - Deployment

    @Test("Deploy backs up Wine's originals and places the payload")
    func deploy() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)

        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        let backup = store.appending(path: "originals").appending(path: "d3d11.dll")
        let backupData = try Data(contentsOf: backup)
        #expect(backupData.suffix(13) == Data("wine original".utf8))

        let wineLib = runtime.appending(path: "Wine").appending(path: "lib")
        let deployed = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
            .appending(path: "dxgi.dll")
        #expect(FileManager.default.fileExists(atPath: deployed.path(percentEncoded: false)))
        #expect(GPTKImporter.isDeployed(inLibraryFolder: runtime))

        let link = wineLib.appending(path: "wine").appending(path: "x86_64-unix")
            .appending(path: "d3d12.so")
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        #expect(destination == GPTKImporter.unixLinkDestination)
    }

    @Test("Redeploying never overwrites the backed-up originals")
    func redeployKeepsOriginals() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)

        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        let backup = store.appending(path: "originals").appending(path: "d3d11.dll")
        let backupData = try Data(contentsOf: backup)
        #expect(backupData.suffix(13) == Data("wine original".utf8))
    }

    @Test("Deploying from an empty store fails")
    func deployEmptyStore() throws {
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)

        #expect(throws: GPTKImportError.storeEmpty) {
            try GPTKImporter.deploy(
                fromStore: tempDir.appending(path: "missing"), intoLibraryFolder: runtime
            )
        }
    }

    @Test("Remove restores the originals and clears the payload")
    func removeRestores() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: store)

        let wineLib = runtime.appending(path: "Wine").appending(path: "lib")
        let restored = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
            .appending(path: "d3d11.dll")
        let restoredData = try Data(contentsOf: restored)
        #expect(restoredData.suffix(13) == Data("wine original".utf8))
        #expect(!GPTKImporter.isDeployed(inLibraryFolder: runtime))

        let external = wineLib.appending(path: "external")
        #expect(!FileManager.default.fileExists(atPath: external.path(percentEncoded: false)))
    }

    // MARK: - Surviving a runtime install

    @Test("The store and its backups survive a runtime reinstall")
    func storeSurvivesRuntimeInstall() throws {
        let appSupport = tempDir.appending(path: "AppSupport")
        let store = GPTKImporter.storeFolder(inApplicationFolder: appSupport)
        let lib = tempDir.appending(path: "payload")
        try makePayload(at: lib)
        let payload = try GPTKImporter.validatePayload(at: lib, isAppleSigned: { _, _ in true })
        try GPTKImporter.importPayload(payload, intoStore: store)

        let runtime = appSupport.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        let tarball = try makeLibrariesTarball(in: tempDir.appending(path: "archive"))
        try WhiskyWineInstaller.install(tarball: tarball, into: appSupport)

        #expect(GPTKImporter.storedRecord(inStore: store)?.gptkVersion == "4.0b2")
        let backup = store.appending(path: "originals").appending(path: "d3d11.dll")
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
    }

    @Test("A new engine discards backups taken from the previous one")
    func redeployAfterEngineChangeRetakesOriginals() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try writeRuntimeVersion(at: runtime, 4, 0, 0)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        try makeRuntime(at: runtime, marker: "wine 11 original")
        try writeRuntimeVersion(at: runtime, 5, 0, 0)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        let backup = store.appending(path: "originals").appending(path: "d3d11.dll")
        let backupData = try Data(contentsOf: backup)
        #expect(backupData.suffix(16) == Data("wine 11 original".utf8))
    }

    @Test("Remove drops backups from a replaced engine instead of restoring them")
    func removeDiscardsStaleOriginals() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try writeRuntimeVersion(at: runtime, 4, 0, 0)
        try GPTKImporter.deploy(fromStore: store, intoLibraryFolder: runtime)

        // A runtime install replaced the tree without a redeploy in between.
        try makeRuntime(at: runtime, marker: "wine 11 original")
        try writeRuntimeVersion(at: runtime, 5, 0, 0)

        try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: store)

        let current = runtime.appending(path: "Wine").appending(path: "lib")
            .appending(path: "wine").appending(path: "x86_64-windows").appending(path: "d3d11.dll")
        let currentData = try Data(contentsOf: current)
        #expect(currentData.suffix(16) == Data("wine 11 original".utf8))

        let backup = store.appending(path: "originals").appending(path: "d3d11.dll")
        #expect(!FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
    }

    @Test("Remove spares Wine builtins an interrupted deploy never swapped")
    func removeSparesUntouchedBuiltins() throws {
        let store = try makeImportedStore(in: tempDir)
        let runtime = tempDir.appending(path: "Libraries")
        try makeRuntime(at: runtime)
        try writeRuntimeVersion(at: runtime, 4, 0, 0)
        let peDir = try makePartialDeploy(store: store, runtime: runtime, runtimeVersion: "4.0.0")

        try GPTKImporter.remove(fromLibraryFolder: runtime, usingStore: store)

        // Swapped, backed up only, and never touched all end as Wine's own.
        for name in ["d3d10.dll", "d3d11.dll", "d3d12.dll"] {
            let data = try Data(contentsOf: peDir.appending(path: name))
            #expect(data.suffix(13) == Data("wine original".utf8))
        }
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
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: unix.path) == GPTKImporter.unixLinkDestination)
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
        let runtimeA = tempDir.appending(path: "Runtimes/runtime-a")
        let runtimeB = tempDir.appending(path: "Runtimes/runtime-b")
        try makeRuntime(at: runtimeA, marker: "Wine A original")
        try makeRuntime(at: runtimeB, marker: "Wine B original")
        let runtimeInfo = WhiskyWineVersion(version: SemanticVersion(4, 0, 0), gptkCapable: true)
        let installed = [
            InstalledWineRuntime(identifier: "runtime-a", libraryFolder: runtimeA, versionInfo: runtimeInfo),
            InstalledWineRuntime(identifier: "runtime-b", libraryFolder: runtimeB, versionInfo: runtimeInfo)
        ]
        for runtime in installed {
            try GPTKImporter.deploy(
                fromStore: store,
                intoLibraryFolder: runtime.libraryFolder,
                originalsFolder: GPTKImporter.originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
            )
        }
        let targets = GPTKImporter.deployedRuntimes(from: installed, usingStore: store)
        #expect(targets.map(\.identifier).sorted() == ["runtime-a", "runtime-b"])

        let newPayloadRoot = tempDir.appending(path: "updated-payload")
        try makePayload(at: newPayloadRoot, version: "4.1.0")
        let updatedPayload = try GPTKImporter.validatePayload(at: newPayloadRoot, isAppleSigned: { _, _ in true })
        _ = try GPTKImporter.importPayload(
            updatedPayload,
            intoStore: store,
            revalidatingWith: { _, _ in true },
            beforeReplacingStoredPayload: {
                try GPTKImporter.remove(fromLibraryFolder: runtimeA, usingStore: store,
                                        originalsFolder: GPTKImporter.originalsFolder(inStore: store, runtimeIdentifier: "runtime-a"))
                try GPTKImporter.remove(fromLibraryFolder: runtimeB, usingStore: store,
                                        originalsFolder: GPTKImporter.originalsFolder(inStore: store, runtimeIdentifier: "runtime-b"))
            },
            afterReplacingStoredPayload: { _ in
                try GPTKImporter.redeployStoredPayloads(to: targets, usingStore: store) { runtime in
                    try GPTKImporter.deploy(
                        fromStore: store,
                        intoLibraryFolder: runtime.libraryFolder,
                        originalsFolder: GPTKImporter.originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
                    )
                }
            }
        )

        #expect(GPTKImporter.storedRecord(inStore: store)?.gptkVersion == "4.1.0")
        #expect(installed.allSatisfy {
            GPTKImporter.isStorePayloadDeployed(inLibraryFolder: $0.libraryFolder, usingStore: store)
        })
        for runtime in installed {
            let backup = GPTKImporter.originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
                .appending(path: "d3d11.dll")
            let marker = Data("Wine \(runtime.identifier.suffix(1).uppercased()) original".utf8)
            #expect(try Data(contentsOf: backup).suffix(marker.count) == marker)
        }
    }

    // MARK: - Runtime capability flag

    @Test("gptkCapable decodes when present and stays nil when absent")
    func gptkCapableDecoding() throws {
        let capable = WhiskyWineVersion(
            version: .init(4, 0, 0), gptkCapable: true
        )
        let encoder = PropertyListEncoder()
        let decoded = try PropertyListDecoder().decode(
            WhiskyWineVersion.self, from: encoder.encode(capable)
        )
        #expect(decoded.gptkCapable == true)

        let legacy = WhiskyWineVersion(version: .init(3, 1, 1))
        let decodedLegacy = try PropertyListDecoder().decode(
            WhiskyWineVersion.self, from: encoder.encode(legacy)
        )
        #expect(decodedLegacy.gptkCapable == nil)
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
