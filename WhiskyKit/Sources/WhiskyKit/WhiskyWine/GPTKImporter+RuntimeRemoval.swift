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

            let fileManager = FileManager.default
            let originalsRoot = store.appending(path: "runtime-originals")
            var processedIdentifiers = Set<String>()
            if fileManager.fileExists(atPath: originalsRoot.path(percentEncoded: false)) {
                let originalsValues = try originalsRoot.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard originalsValues.isDirectory == true, originalsValues.isSymbolicLink != true else {
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

                for backup in backups {
                    let identifier = backup.lastPathComponent
                    guard let libraryFolder = WineRuntimeStore.libraryFolder(identifier: identifier),
                          identifier != WineRuntimeStore.defaultRuntimeIdentifier
                    else { continue }
                    let backupValues = try backup.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard backupValues.isDirectory == true, backupValues.isSymbolicLink != true else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: backup.path])
                    }
                    guard fileManager.fileExists(atPath: libraryFolder.path(percentEncoded: false)) else { continue }
                    let runtimeValues = try libraryFolder.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                    )
                    guard runtimeValues.isDirectory == true, runtimeValues.isSymbolicLink != true else {
                        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: libraryFolder.path])
                    }

                    try remove(
                        fromLibraryFolder: libraryFolder,
                        usingStore: store,
                        originalsFolder: backup
                    )
                    processedIdentifiers.insert(identifier)
                }
            }

            // A crash can interrupt deployment before its per-runtime backup
            // record is created, or interrupt removal after the backup is
            // already gone. Clean only fragments that still match this store;
            // arbitrary files in an incomplete runtime are left in place.
            for runtime in namedRuntimeFolders where !processedIdentifiers.contains(runtime.identifier) {
                guard hasStoreManagedFragments(inLibraryFolder: runtime.libraryFolder, usingStore: store) else {
                    continue
                }
                try remove(
                    fromLibraryFolder: runtime.libraryFolder,
                    usingStore: store,
                    originalsFolder: originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
                )
            }
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
            let fileManager = FileManager.default
            let wineLib = folder.appending(path: "Wine").appending(path: "lib")
            let peDir = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
            let unixDir = wineLib.appending(path: "wine").appending(path: "x86_64-unix")
            let originals = suppliedOriginalsFolder ?? store.appending(path: "originals")
            let storeLib = store.appending(path: "lib")

            let recordStamp = originalsRecord(inOriginalsFolder: originals)?.runtimeVersion
            let runtimeStamp = runtimeVersionStamp(inLibraryFolder: folder)
            let runtimeVersion = runtimeVersionNumber(inLibraryFolder: folder)
            let backupNames = forwarderDLLNames.filter {
                fileManager.fileExists(atPath: originals.appending(path: $0).path(percentEncoded: false))
            }
            if holdsHandPlacedPayload(inLibraryFolder: folder, usingStore: store),
               recordStamp == nil, backupNames.isEmpty {
                logger.info("Left a GPTK payload copied into the runtime by hand in place")
                return
            }
            let originalsAreCurrent = recordStamp != nil && runtimeStamp != nil && recordStamp == runtimeStamp
            let backupsAreStale: Bool

            if backupNames.isEmpty {
                backupsAreStale = false
            } else if originalsAreCurrent {
                for name in backupNames {
                    let deployed = peDir.appending(path: name)
                    guard fileManager.fileExists(atPath: deployed.path(percentEncoded: false)) else { continue }
                    let isKnownInterposer = interposers.contains {
                        $0.slotName == name && isInstalled($0, inLibraryFolder: folder)
                    }
                    guard isKnownInterposer || isGPTKForwarder(deployed, matching: storeLib) else {
                        throw GPTKImportError.runtimeOriginalsUnverified(folder.lastPathComponent)
                    }
                }
                backupsAreStale = false
            } else if let recordStamp, let runtimeStamp, recordStamp.hasPrefix("runtime:") {
                // A full build fingerprint proves this is a different runtime,
                // even when two prereleases share the same numeric version.
                backupsAreStale = recordStamp != runtimeStamp
            } else if let recordStamp, let runtimeVersion,
                      recordStamp.split(separator: ".").count == 3,
                      recordStamp != runtimeVersion {
                // Older app versions recorded only major.minor.patch. A different
                // numeric version is enough to identify a replaced Wine engine.
                backupsAreStale = true
            } else {
                throw GPTKImportError.runtimeOriginalsUnverified(folder.lastPathComponent)
            }

            removeMetalFXBridge(fromLibraryFolder: folder, usingStore: store)
            // Apple's DLL goes back into the d3d12 slot before the loop reads it,
            // or the slot still holds the interposer, fails the byte match against
            // the store, and is skipped: the tree would keep a d3d12 that forwards
            // to a DLL this call is about to delete.
            removeVideoProcessor(fromLibraryFolder: folder, usingStore: store)
            removeNVAPIBridge(fromLibraryFolder: folder, usingStore: store)

            for name in forwarderDLLNames {
                let backup = originals.appending(path: name)
                let hasBackup = fileManager.fileExists(atPath: backup.path(percentEncoded: false))

                // Backups from a replaced engine: drop them and leave the tree,
                // which this store never deployed into, untouched.
                guard originalsAreCurrent else {
                    if hasBackup {
                        guard backupsAreStale else {
                            throw GPTKImportError.runtimeOriginalsUnverified(folder.lastPathComponent)
                        }
                        try fileManager.removeItem(at: backup)
                    }
                    let deployed = peDir.appending(path: name)
                    if fileManager.fileExists(atPath: deployed.path(percentEncoded: false)),
                       isGPTKForwarder(deployed, matching: storeLib) {
                        try fileManager.removeItem(at: deployed)
                    }
                    continue
                }

                // An interrupted deploy leaves some names still holding Wine's own
                // DLL, never backed up; deleting one loses a builtin with nothing
                // to put back. Only what byte-matches the store came from here.
                let deployed = peDir.appending(path: name)
                if fileManager.fileExists(atPath: deployed.path(percentEncoded: false)) {
                    guard isGPTKForwarder(deployed, matching: storeLib) else { continue }
                    try fileManager.removeItem(at: deployed)
                }
                if hasBackup {
                    if fileManager.fileExists(atPath: deployed.path(percentEncoded: false)) {
                        throw GPTKImportError.runtimeOriginalsUnverified(folder.lastPathComponent)
                    }
                    try fileManager.moveItem(at: backup, to: deployed)
                }
            }

            // removeItem operates on the link itself, so this also clears a
            // dangling symlink that fileExists (which follows links) would miss.
            for name in unixLibraryNames {
                let link = unixDir.appending(path: name)
                guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)),
                      destination == unixLinkDestination
                else { continue }
                try fileManager.removeItem(at: link)
            }

            let external = wineLib.appending(path: "external")
            let storeExternal = storeLib.appending(path: "external")
            if let externalValues = try? external.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               externalValues.isDirectory == true,
               externalValues.isSymbolicLink != true,
               let storeItems = try? fileManager.contentsOfDirectory(at: storeExternal, includingPropertiesForKeys: nil) {
                for source in storeItems {
                    let item = external.appending(path: source.lastPathComponent)
                    try removeMatchingStoreItems(from: item, matching: source)
                }
                if (try? fileManager.contentsOfDirectory(atPath: external.path(percentEncoded: false)))?.isEmpty == true {
                    try fileManager.removeItem(at: external)
                }
            }
            logger.info("Removed GPTK payload from the runtime tree")
        }
    }
}
