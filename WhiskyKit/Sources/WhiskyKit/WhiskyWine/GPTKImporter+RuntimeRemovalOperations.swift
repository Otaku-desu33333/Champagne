//
//  GPTKImporter+RuntimeRemovalOperations.swift
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

struct GPTKRuntimeRemovalContext {
    let libraryFolder: URL
    let originalsFolder: URL
    let peDirectory: URL
    let unixDirectory: URL
    let storeLib: URL
    let originalsAreCurrent: Bool
    let backupsAreStale: Bool
}

private struct GPTKBackupValidation {
    let backupNames: [String]
    let peDirectory: URL
    let originalsAreCurrent: Bool
    let recordStamp: String?
    let runtimeStamp: String?
    let runtimeVersion: String?
    let runtimeName: String
    let storeLib: URL
    let libraryFolder: URL
}

extension GPTKImporter {
    static func makeRemovalContext(
        fromLibraryFolder folder: URL,
        usingStore store: URL,
        originalsFolder suppliedOriginalsFolder: URL?
    ) throws -> GPTKRuntimeRemovalContext? {
        let fileManager = FileManager.default
        let wineLib = folder.appending(path: "Wine/lib")
        let peDirectory = wineLib.appending(path: "wine/x86_64-windows")
        let unixDirectory = wineLib.appending(path: "wine/x86_64-unix")
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
            return nil
        }

        let originalsAreCurrent = recordStamp != nil && runtimeStamp != nil && recordStamp == runtimeStamp
        let backupsAreStale = try validateBackups(GPTKBackupValidation(
            backupNames: backupNames,
            peDirectory: peDirectory,
            originalsAreCurrent: originalsAreCurrent,
            recordStamp: recordStamp,
            runtimeStamp: runtimeStamp,
            runtimeVersion: runtimeVersion,
            runtimeName: folder.lastPathComponent,
            storeLib: storeLib,
            libraryFolder: folder
        ))
        return GPTKRuntimeRemovalContext(
            libraryFolder: folder,
            originalsFolder: originals,
            peDirectory: peDirectory,
            unixDirectory: unixDirectory,
            storeLib: storeLib,
            originalsAreCurrent: originalsAreCurrent,
            backupsAreStale: backupsAreStale
        )
    }

    private static func validateBackups(_ validation: GPTKBackupValidation) throws -> Bool {
        guard !validation.backupNames.isEmpty else { return false }
        if validation.originalsAreCurrent {
            try verifyCurrentBackups(
                named: validation.backupNames,
                in: validation.peDirectory,
                storeLib: validation.storeLib,
                libraryFolder: validation.libraryFolder,
                runtimeName: validation.runtimeName
            )
            return false
        }
        if let recordStamp = validation.recordStamp, let runtimeStamp = validation.runtimeStamp,
           recordStamp.hasPrefix("runtime:") {
            // A full fingerprint distinguishes prereleases with the same numeric version.
            return recordStamp != runtimeStamp
        }
        if let recordStamp = validation.recordStamp, let runtimeVersion = validation.runtimeVersion,
           recordStamp.split(separator: ".").count == 3,
           recordStamp != runtimeVersion {
            // Legacy stamps identify a replacement only when the numeric version changed.
            return true
        }
        throw GPTKImportError.runtimeOriginalsUnverified(validation.runtimeName)
    }

    private static func verifyCurrentBackups(
        named backupNames: [String],
        in peDirectory: URL,
        storeLib: URL,
        libraryFolder: URL,
        runtimeName: String
    ) throws {
        let fileManager = FileManager.default
        for name in backupNames {
            let deployed = peDirectory.appending(path: name)
            guard fileManager.fileExists(atPath: deployed.path(percentEncoded: false)) else { continue }
            let isKnownInterposer = interposers.contains {
                $0.slotName == name && isInstalled($0, inLibraryFolder: libraryFolder)
            }
            guard isKnownInterposer || isGPTKForwarder(deployed, matching: storeLib) else {
                throw GPTKImportError.runtimeOriginalsUnverified(runtimeName)
            }
        }
    }

    static func removeGraphicsBridges(fromLibraryFolder folder: URL, usingStore store: URL) {
        removeMetalFXBridge(fromLibraryFolder: folder, usingStore: store)
        // Restore Apple's DLL before examining the d3d12 slot; it may currently hold the interposer.
        removeVideoProcessor(fromLibraryFolder: folder, usingStore: store)
        removeNVAPIBridge(fromLibraryFolder: folder, usingStore: store)
    }

    static func restoreForwarders(using context: GPTKRuntimeRemovalContext) throws {
        let fileManager = FileManager.default
        for name in forwarderDLLNames {
            let backup = context.originalsFolder.appending(path: name)
            let hasBackup = fileManager.fileExists(atPath: backup.path(percentEncoded: false))
            let deployed = context.peDirectory.appending(path: name)
            if !context.originalsAreCurrent {
                if hasBackup {
                    guard context.backupsAreStale else {
                        throw GPTKImportError.runtimeOriginalsUnverified(context.libraryFolder.lastPathComponent)
                    }
                    try fileManager.removeItem(at: backup)
                }
                if fileManager.fileExists(atPath: deployed.path(percentEncoded: false)),
                   isGPTKForwarder(deployed, matching: context.storeLib) {
                    try fileManager.removeItem(at: deployed)
                }
                continue
            }
            if fileManager.fileExists(atPath: deployed.path(percentEncoded: false)) {
                guard isGPTKForwarder(deployed, matching: context.storeLib) else { continue }
                try fileManager.removeItem(at: deployed)
            }
            if hasBackup {
                guard !fileManager.fileExists(atPath: deployed.path(percentEncoded: false)) else {
                    throw GPTKImportError.runtimeOriginalsUnverified(context.libraryFolder.lastPathComponent)
                }
                try fileManager.moveItem(at: backup, to: deployed)
            }
        }
    }

    static func removeUnixBridges(in unixDirectory: URL) throws {
        let fileManager = FileManager.default
        for name in unixLibraryNames {
            let link = unixDirectory.appending(path: name)
            guard let destination = try? fileManager
                .destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)),
                destination == unixLinkDestination
            else { continue }
            try fileManager.removeItem(at: link)
        }
    }

    static func removeExternalPayload(from folder: URL, usingStore store: URL) throws {
        let fileManager = FileManager.default
        let external = folder.appending(path: "Wine/lib/external")
        let storeExternal = store.appending(path: "lib/external")
        guard let values = try? external.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true,
              let items = try? fileManager.contentsOfDirectory(at: storeExternal, includingPropertiesForKeys: nil)
        else { return }
        for source in items {
            try removeMatchingStoreItems(
                from: external.appending(path: source.lastPathComponent),
                matching: source
            )
        }
        if (try? fileManager.contentsOfDirectory(atPath: external.path(percentEncoded: false)))?.isEmpty == true {
            try fileManager.removeItem(at: external)
        }
    }
}
