//
//  GPTKImporter+RuntimeRemoval.swift
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

/// Removes imported GPTK data and restores runtime files it replaced.
extension GPTKImporter {
    /// The stored payload's record, or `nil` when the store is absent or its
    /// payload is incomplete.
    public static func storedRecord() -> GPTKStoreRecord? {
        storedRecord(inStore: storeFolder)
    }

    /// Testable seam for ``storedRecord()``.
    static func storedRecord(inStore store: URL) -> GPTKStoreRecord? {
        guard let data = try? Data(contentsOf: recordURL(inStore: store)),
              let record = try? PropertyListDecoder().decode(GPTKStoreRecord.self, from: data),
              isPayloadRoot(store.appending(path: "lib"))
        else { return nil }
        return record
    }

    /// Deletes the store, payload and record together.
    public static func removeStore() throws {
        try withFileOperationLock {
            let store = storeFolder
            guard FileManager.default.fileExists(atPath: store.path(percentEncoded: false)) else { return }
            try removeDeployedPayloadsFromAllRuntimes()
            try FileManager.default.removeItem(at: store)
        }
    }

    static func recordURL(inStore store: URL) -> URL {
        store.appending(path: "D3DMetalVersion.plist")
    }

    /// Removes the payload from the runtime tree and restores the backed-up
    /// Wine originals.
    public static func removeDeployedPayload() throws {
        try withFileOperationLock {
            try remove(fromLibraryFolder: WhiskyWineInstaller.libraryFolder, usingStore: storeFolder)
        }
    }

    /// Removes GPTK from a named runtime and restores that runtime's own Wine
    /// DLL backups.
    public static func removeDeployedPayload(forRuntime identifier: String) throws {
        try withFileOperationLock {
            guard identifier != WineRuntimeStore.defaultRuntimeIdentifier else {
                try removeDeployedPayload()
                return
            }
            guard let runtime = WineRuntimeStore.runtime(identifier: identifier) else {
                throw WineRuntimeStoreError.runtimeNotInstalled(identifier)
            }
            try remove(
                fromLibraryFolder: runtime.libraryFolder,
                usingStore: storeFolder,
                originalsFolder: originalsFolder(inStore: storeFolder, runtimeIdentifier: runtime.identifier)
            )
        }
    }

    /// Restores GPTK-managed files in the default runtime and every named
    /// runtime with an isolated originals backup. Called before replacing or
    /// deleting the store so a runtime never loses the only copy of its Wine
    /// DLLs while the corresponding backup is discarded.
    static func removeDeployedPayloadsFromAllRuntimes() throws {
        try withFileOperationLock {
            try removeDeployedPayloads(
                fromDefaultRuntime: WhiskyWineInstaller.libraryFolder,
                namedRuntimeFolders: namedRuntimeFoldersOnDisk(at: WineRuntimeStore.runtimesDirectory),
                usingStore: storeFolder
            )
        }
    }

    /// Test seam for store replacement/removal, including runtimes whose
    /// directory is incomplete and therefore absent from `installedRuntimes()`.
    static func removeDeployedPayloads(
        fromDefaultRuntime defaultRuntime: URL,
        namedRuntimeFolders: [(identifier: String, libraryFolder: URL)],
        usingStore store: URL
    ) throws {
        try withFileOperationLock {
            try remove(fromLibraryFolder: defaultRuntime, usingStore: store)
            let originalsRoot = store.appending(path: "runtime-originals")
            let processedIdentifiers = try removeRecordedRuntimeBackups(
                at: originalsRoot,
                usingStore: store
            )
            try removeUnrecordedRuntimeFragments(
                from: namedRuntimeFolders,
                excluding: processedIdentifiers,
                usingStore: store
            )
        }
    }

    private static func removeRecordedRuntimeBackups(
        at originalsRoot: URL,
        usingStore store: URL
    ) throws -> Set<String> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: originalsRoot.path(percentEncoded: false)) else { return [] }
        let rootValues = try originalsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [NSFilePathErrorKey: originalsRoot.path(percentEncoded: false)]
            )
        }
        let backups = try fileManager.contentsOfDirectory(
            at: originalsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var processed = Set<String>()
        for backup in backups {
            guard let (identifier, libraryFolder) = try runtimeFolder(forBackup: backup) else { continue }
            try remove(fromLibraryFolder: libraryFolder, usingStore: store, originalsFolder: backup)
            processed.insert(identifier)
        }
        return processed
    }

    private static func runtimeFolder(forBackup backup: URL) throws -> (String, URL)? {
        let identifier = backup.lastPathComponent
        guard identifier != WineRuntimeStore.defaultRuntimeIdentifier,
              let libraryFolder = WineRuntimeStore.libraryFolder(identifier: identifier)
        else { return nil }
        let backupValues = try backup.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard backupValues.isDirectory == true, backupValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: backup.path])
        }
        guard FileManager.default.fileExists(atPath: libraryFolder.path(percentEncoded: false)) else { return nil }
        let runtimeValues = try libraryFolder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard runtimeValues.isDirectory == true, runtimeValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: libraryFolder.path])
        }
        return (identifier, libraryFolder)
    }

    private static func removeUnrecordedRuntimeFragments(
        from namedRuntimeFolders: [(identifier: String, libraryFolder: URL)],
        excluding processedIdentifiers: Set<String>,
        usingStore store: URL
    ) throws {
        // A crash can interrupt deployment before its per-runtime backup record
        // is created, or interrupt removal after the backup is already gone.
        for runtime in namedRuntimeFolders where !processedIdentifiers.contains(runtime.identifier) {
            guard hasStoreManagedFragments(inLibraryFolder: runtime.libraryFolder, usingStore: store) else { continue }
            try remove(
                fromLibraryFolder: runtime.libraryFolder,
                usingStore: store,
                originalsFolder: originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
            )
        }
    }

    static func namedRuntimeFoldersOnDisk(
        at root: URL
    ) throws -> [(identifier: String, libraryFolder: URL)] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .compactMap { folder in
                let identifier = folder.lastPathComponent
                guard identifier != WineRuntimeStore.defaultRuntimeIdentifier,
                      (try? WineRuntimeStore.validatedIdentifier(identifier)) != nil
                else { return nil }
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
                return (identifier, folder)
            }
    }

    private static func hasStoreManagedFragments(inLibraryFolder folder: URL, usingStore store: URL) -> Bool {
        let fileManager = FileManager.default
        let storeLib = store.appending(path: "lib")
        let peDir = folder.appending(path: "Wine").appending(path: "lib").appending(path: "wine")
            .appending(path: "x86_64-windows")
        if forwarderDLLNames.contains(where: {
            isGPTKForwarder(peDir.appending(path: $0), matching: storeLib)
        }) || isNVAPIBridgeInstalled(inLibraryFolder: folder, usingStore: store)
            || isMetalFXBridgeInstalled(inLibraryFolder: folder, usingStore: store) {
            return true
        }

        let unixDir = folder.appending(path: "Wine").appending(path: "lib").appending(path: "wine")
            .appending(path: "x86_64-unix")
        if (unixLibraryNames + [nvapiBridgeUnixName, metalFXBridgeUnixName]).contains(where: { name in
            (try? fileManager.destinationOfSymbolicLink(
                atPath: unixDir.appending(path: name).path(percentEncoded: false)
            )) == unixLinkDestination
        }) {
            return true
        }

        let external = folder.appending(path: "Wine").appending(path: "lib").appending(path: "external")
        let storeExternal = storeLib.appending(path: "external")
        guard let storeItems = try? fileManager.contentsOfDirectory(at: storeExternal, includingPropertiesForKeys: nil)
        else { return false }
        return storeItems.contains { source in
            fileSystemItemsMatch(external.appending(path: source.lastPathComponent), source)
        }
    }

    /// Testable seam for ``removeDeployedPayload()``.
    static func remove(
        fromLibraryFolder folder: URL,
        usingStore store: URL,
        originalsFolder suppliedOriginalsFolder: URL? = nil
    ) throws {
        try withFileOperationLock {
            guard let context = try makeRemovalContext(
                fromLibraryFolder: folder,
                usingStore: store,
                originalsFolder: suppliedOriginalsFolder
            )
            else { return }
            removeGraphicsBridges(fromLibraryFolder: folder, usingStore: store)
            try restoreForwarders(using: context)
            try removeUnixBridges(in: context.unixDirectory)
            try removeExternalPayload(from: context.libraryFolder, usingStore: store)
            logger.info("Removed GPTK payload from the runtime tree")
        }
    }
}
