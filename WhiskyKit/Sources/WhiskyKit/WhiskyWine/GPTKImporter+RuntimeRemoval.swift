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
        let store = storeFolder
        guard FileManager.default.fileExists(atPath: store.path(percentEncoded: false)) else { return }
        try removeDeployedPayloadsFromAllRuntimes()
        try FileManager.default.removeItem(at: store)
    }

    static func recordURL(inStore store: URL) -> URL {
        store.appending(path: "D3DMetalVersion.plist")
    }

    /// Removes the payload from the runtime tree and restores the backed-up
    /// Wine originals.
    public static func removeDeployedPayload() throws {
        try remove(fromLibraryFolder: WhiskyWineInstaller.libraryFolder, usingStore: storeFolder)
    }

    /// Removes GPTK from a named runtime and restores that runtime's own Wine
    /// DLL backups.
    public static func removeDeployedPayload(forRuntime identifier: String) throws {
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

    /// Restores GPTK-managed files in the default runtime and every named
    /// runtime with an isolated originals backup. Called before replacing or
    /// deleting the store so a runtime never loses the only copy of its Wine
    /// DLLs while the corresponding backup is discarded.
    static func removeDeployedPayloadsFromAllRuntimes() throws {
        let store = storeFolder
        try remove(fromLibraryFolder: WhiskyWineInstaller.libraryFolder, usingStore: store)

        let originalsRoot = store.appending(path: "runtime-originals")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: originalsRoot.path(percentEncoded: false)) else { return }
        let originalsValues = try originalsRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
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
            let runtimeValues = try libraryFolder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard runtimeValues.isDirectory == true, runtimeValues.isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: libraryFolder.path])
            }

            try remove(
                fromLibraryFolder: libraryFolder,
                usingStore: store,
                originalsFolder: backup
            )
        }
    }

    /// Testable seam for ``removeDeployedPayload()``.
    static func remove(
        fromLibraryFolder folder: URL,
        usingStore store: URL,
        originalsFolder suppliedOriginalsFolder: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        let wineLib = folder.appending(path: "Wine").appending(path: "lib")
        let peDir = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
        let unixDir = wineLib.appending(path: "wine").appending(path: "x86_64-unix")
        let originals = suppliedOriginalsFolder ?? store.appending(path: "originals")
        let storeLib = store.appending(path: "lib")

        let originalsAreCurrent = originalsRecord(inOriginalsFolder: originals)?.runtimeVersion
            == runtimeVersionStamp(inLibraryFolder: folder)

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
                    try fileManager.removeItem(at: backup)
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
                try fileManager.moveItem(at: backup, to: deployed)
            }
        }

        // removeItem operates on the link itself, so this also clears a
        // dangling symlink that fileExists (which follows links) would miss.
        for name in unixLibraryNames {
            try? fileManager.removeItem(at: unixDir.appending(path: name))
        }

        let external = wineLib.appending(path: "external")
        if fileManager.fileExists(atPath: external.path(percentEncoded: false)) {
            try fileManager.removeItem(at: external)
        }
        logger.info("Removed GPTK payload from the runtime tree")
    }
}
