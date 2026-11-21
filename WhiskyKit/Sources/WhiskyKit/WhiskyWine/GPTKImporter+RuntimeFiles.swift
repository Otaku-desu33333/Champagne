//
//  GPTKImporter+RuntimeFiles.swift
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

/// Helpers for comparing, recording, and preserving runtime files managed by GPTK.
extension GPTKImporter {
    /// Compares copied payload items without following links. Used to remove
    /// only exact store-managed files while preserving unrelated runtime data.
    static func fileSystemItemsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        let fileManager = FileManager.default
        guard let lhsValues = try? lhs.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              let rhsValues = try? rhs.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              lhsValues.isSymbolicLink == rhsValues.isSymbolicLink,
              lhsValues.isDirectory == rhsValues.isDirectory
        else { return false }

        if lhsValues.isSymbolicLink == true {
            guard let lhsDestination = try? fileManager
                .destinationOfSymbolicLink(atPath: lhs.path(percentEncoded: false)),
                let rhsDestination = try? fileManager
                .destinationOfSymbolicLink(atPath: rhs.path(percentEncoded: false))
            else { return false }
            return lhsDestination == rhsDestination
        }

        if lhsValues.isDirectory == true {
            guard let lhsChildren = try? fileManager.contentsOfDirectory(at: lhs, includingPropertiesForKeys: nil),
                  let rhsChildren = try? fileManager.contentsOfDirectory(at: rhs, includingPropertiesForKeys: nil)
            else { return false }
            let lhsByName = Dictionary(uniqueKeysWithValues: lhsChildren.map { ($0.lastPathComponent, $0) })
            let rhsByName = Dictionary(uniqueKeysWithValues: rhsChildren.map { ($0.lastPathComponent, $0) })
            guard Set(lhsByName.keys) == Set(rhsByName.keys) else { return false }
            return lhsByName.allSatisfy { name, child in
                guard let rhsChild = rhsByName[name] else { return false }
                return fileSystemItemsMatch(child, rhsChild)
            }
        }

        return fileManager.contentsEqual(
            atPath: lhs.path(percentEncoded: false),
            andPath: rhs.path(percentEncoded: false)
        )
    }

    /// Removes a store item only when it still matches the copied source. For
    /// partially copied directories, it descends into matching names and keeps
    /// unrelated files rather than deleting the containing directory.
    static func removeMatchingStoreItems(from destination: URL, matching source: URL) throws {
        let fileManager = FileManager.default
        if fileSystemItemsMatch(destination, source) {
            try fileManager.removeItem(at: destination)
            return
        }

        guard let destinationValues = try? destination.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
            destinationValues.isDirectory == true,
            destinationValues.isSymbolicLink != true,
            let sourceValues = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            sourceValues.isDirectory == true,
            sourceValues.isSymbolicLink != true,
            let sourceChildren = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        else { return }

        for sourceChild in sourceChildren {
            try removeMatchingStoreItems(
                from: destination.appending(path: sourceChild.lastPathComponent),
                matching: sourceChild
            )
        }
        if (try? fileManager.contentsOfDirectory(atPath: destination.path(percentEncoded: false)))?.isEmpty == true {
            try fileManager.removeItem(at: destination)
        }
    }

    static func originalsRecordURL(inStore store: URL) -> URL {
        store.appending(path: "originals").appending(path: "OriginalsVersion.plist")
    }

    /// Backup location for one runtime. The existing default-runtime path is
    /// retained so installations made by earlier Champagne versions still
    /// restore their original Wine DLLs correctly.
    static func originalsFolder(inStore store: URL, runtimeIdentifier: String) -> URL {
        if runtimeIdentifier == WineRuntimeStore.defaultRuntimeIdentifier {
            return store.appending(path: "originals")
        }
        return store.appending(path: "runtime-originals").appending(path: runtimeIdentifier)
    }

    static func originalsRecord(inStore store: URL) -> GPTKOriginalsRecord? {
        guard let data = try? Data(contentsOf: originalsRecordURL(inStore: store)) else { return nil }
        return try? PropertyListDecoder().decode(GPTKOriginalsRecord.self, from: data)
    }

    /// Readies the `originals/` folder for a deploy against `folder`, dropping
    /// backups left by a previous engine: restoring those would put that
    /// engine's DLLs into this one's tree. The stamp is written before the first
    /// backup so an interrupted deploy still leaves originals remove will
    /// recognise and restore.
    static func prepareOriginals(
        originalsFolder originals: URL,
        forLibraryFolder folder: URL
    ) throws {
        let fileManager = FileManager.default
        guard let runtimeStamp = runtimeVersionStamp(inLibraryFolder: folder),
              let runtimeVersion = runtimeVersionNumber(inLibraryFolder: folder)
        else {
            throw GPTKImportError.runtimeOriginalsUnverified(folder.lastPathComponent)
        }

        let recordStamp = originalsRecord(inOriginalsFolder: originals)?.runtimeVersion
        let hasBackups = forwarderDLLNames.contains {
            fileManager.fileExists(atPath: originals.appending(path: $0).path(percentEncoded: false))
        }
        if recordStamp != runtimeStamp, fileManager.fileExists(atPath: originals.path(percentEncoded: false)) {
            if hasBackups {
                let legacyVersion = recordStamp.flatMap { stamp in
                    stamp.split(separator: ".").count == 3 && !stamp.hasPrefix("runtime:") ? stamp : nil
                }
                let fingerprintChanged = recordStamp?.hasPrefix("runtime:") == true
                let legacyVersionChanged = legacyVersion.map { $0 != runtimeVersion } == true
                guard fingerprintChanged || legacyVersionChanged else {
                    throw GPTKImportError.runtimeOriginalsUnverified(folder.lastPathComponent)
                }
            }
            // A different runtime fingerprint proves that these originals
            // came from an older engine. An old numeric-only stamp is discarded
            // only when its major.minor.patch differs; same-version legacy
            // backups are ambiguous because prereleases were not recorded.
            try fileManager.removeItem(at: originals)
        }
        try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(GPTKOriginalsRecord(runtimeVersion: runtimeStamp))
            .write(to: originalsRecordURL(inOriginalsFolder: originals))
    }

    static func originalsRecordURL(inOriginalsFolder folder: URL) -> URL {
        folder.appending(path: "OriginalsVersion.plist")
    }

    static func originalsRecord(inOriginalsFolder folder: URL) -> GPTKOriginalsRecord? {
        guard let data = try? Data(contentsOf: originalsRecordURL(inOriginalsFolder: folder)) else { return nil }
        return try? PropertyListDecoder().decode(GPTKOriginalsRecord.self, from: data)
    }
}
