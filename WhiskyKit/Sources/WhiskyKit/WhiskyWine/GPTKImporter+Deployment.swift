//
//  GPTKImporter+Deployment.swift
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
import os.log

/// Which runtime the backed-up Wine originals were taken from. The store now
/// outlives the runtime, so a backup can outlive the engine it came from, and
/// restoring a Wine 10 builtin into a Wine 11 tree breaks it silently.
struct GPTKOriginalsRecord: Codable, Equatable, Sendable {
    let runtimeVersion: String
}

/// Runtime capability gating and deployment of the stored payload into the
/// Wine tree (Apple's documented layout).
extension GPTKImporter {
    // MARK: - Runtime capability

    /// Whether the installed runtime's Wine build can execute GPTK payloads.
    ///
    /// Advertised by `gptkCapable` in the runtime's version plist; absent means
    /// no. This is a build property (exception-unwind support), not something
    /// the payload or the app can add.
    public static func isRuntimeGPTKCapable() -> Bool {
        WhiskyWineInstaller.whiskyWineInfo()?.gptkCapable == true
    }

    /// Whether a named installed runtime's Wine build can execute GPTK payloads.
    public static func isRuntimeGPTKCapable(forRuntime identifier: String) -> Bool {
        WineRuntimeStore.runtime(identifier: identifier)?.versionInfo.gptkCapable == true
    }

    // MARK: - Deployment

    /// Whether the payload is deployed into the runtime tree.
    public static func isDeployed() -> Bool {
        isDeployed(inLibraryFolder: WhiskyWineInstaller.libraryFolder)
    }

    /// Whether GPTK is deployed into the Wine runtime selected by a bottle.
    @MainActor
    public static func isDeployed(for bottle: Bottle) -> Bool {
        isDeployed(for: bottle.settings)
    }

    /// Whether GPTK is deployed into the runtime selected by settings.
    public static func isDeployed(for settings: BottleSettings) -> Bool {
        let identifier = settings.wineRuntimeIdentifier ?? WineRuntimeStore.defaultRuntimeIdentifier
        guard let runtime = WineRuntimeStore.runtime(identifier: identifier) else {
            return identifier == WineRuntimeStore.defaultRuntimeIdentifier && isDeployed()
        }
        return isDeployed(inLibraryFolder: runtime.libraryFolder)
    }

    /// Testable seam for ``isDeployed()``: the unix bridge for dxgi and the
    /// shared dylib both present in the Wine tree.
    static func isDeployed(inLibraryFolder folder: URL) -> Bool {
        let lib = folder.appending(path: "Wine").appending(path: "lib")
        let bridge = lib.appending(path: "wine").appending(path: "x86_64-unix").appending(path: "dxgi.so")
        let dylib = lib.appending(path: "external").appending(path: "libd3dshared.dylib")
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: bridge.path(percentEncoded: false)) &&
            fileManager.fileExists(atPath: dylib.path(percentEncoded: false))
    }

    /// Deploys the stored payload into the runtime tree per Apple's documented
    /// layout: forwarders replace the Wine builtins (originals are backed up in
    /// the store), the unix bridges and `external/` are added alongside.
    ///
    /// The runtime capability check is enforced here — deploying to an
    /// incapable runtime turns every D3DMetal launch into a crash.
    ///
    /// - Throws: ``GPTKImportError/storeNotVerified(_:)`` when the store fails
    ///   the checks an import applies (see ``verifyStoredPayload()``).
    public static func deployStoredPayload() throws {
        try withFileOperationLock {
            guard isRuntimeGPTKCapable() else {
                throw WineRuntimeStoreError.runtimeNotGPTKCapable(WineRuntimeStore.defaultRuntimeIdentifier)
            }
            let store = storeFolder
            if case let .failed(reason) = storeVerdict(inStore: store, isAppleSigned: isAppleSigned(_:identifier:)) {
                throw GPTKImportError.storeNotVerified(reason)
            }
            try deploy(fromStore: store, intoLibraryFolder: WhiskyWineInstaller.libraryFolder)
        }
    }

    /// Deploys the imported GPTK payload into a named runtime, keeping Wine's
    /// original DLL backups isolated from every other runtime.
    public static func deployStoredPayload(forRuntime identifier: String) throws {
        try withFileOperationLock {
            guard identifier != WineRuntimeStore.defaultRuntimeIdentifier else {
                try deployStoredPayload()
                return
            }
            guard let runtime = WineRuntimeStore.runtime(identifier: identifier) else {
                throw WineRuntimeStoreError.runtimeNotInstalled(identifier)
            }
            guard runtime.versionInfo.gptkCapable == true else {
                throw WineRuntimeStoreError.runtimeNotGPTKCapable(identifier)
            }
            let store = storeFolder
            if case let .failed(reason)? = verifyStoredPayload(
                inStore: store,
                libraryFolder: runtime.libraryFolder,
                isAppleSigned: isAppleSigned(_:identifier:)
            ) {
                throw GPTKImportError.storeNotVerified(reason)
            }
            try deploy(
                fromStore: store,
                intoLibraryFolder: runtime.libraryFolder,
                originalsFolder: originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
            )
        }
    }

    /// Deploys the stored payload if there is one and the runtime can execute
    /// it, reporting whether it deployed.
    ///
    /// The store survives a runtime install but the deployed copy does not, so
    /// every install has to re-evaluate. Idempotent and safe to call anywhere.
    ///
    /// A runtime holding a payload copied in by hand is left as it is. This
    /// runs without anyone asking, every time Settings opens, and deploying
    /// would replace that payload, deleting its forwarders or filing them away
    /// as Wine's own. Importing is what replaces it.
    ///
    /// A store that fails the checks an import applies is not deployed either
    /// (see ``verifyStoredPayload()``).
    @discardableResult
    public static func deployStoredPayloadIfCapable() -> Bool {
        withFileOperationLock {
            guard isRuntimeGPTKCapable() else { return false }
            return deployStoredPayloadIfPresent(
                fromStore: storeFolder,
                intoLibraryFolder: WhiskyWineInstaller.libraryFolder,
                isAppleSigned: isAppleSigned(_:identifier:)
            )
        }
    }

    /// Deploys the stored GPTK payload to a capable named runtime, if present.
    @discardableResult
    public static func deployStoredPayloadIfCapable(forRuntime identifier: String) -> Bool {
        withFileOperationLock {
            guard let runtime = WineRuntimeStore.runtime(identifier: identifier),
                  runtime.versionInfo.gptkCapable == true
            else { return false }
            let store = storeFolder
            let verdict = verifyStoredPayload(
                inStore: store,
                libraryFolder: runtime.libraryFolder,
                isAppleSigned: isAppleSigned(_:identifier:)
            )
            guard verdict == .verified,
                  !holdsHandPlacedPayload(inLibraryFolder: runtime.libraryFolder, usingStore: store)
            else { return false }
            do {
                try deploy(
                    fromStore: store,
                    intoLibraryFolder: runtime.libraryFolder,
                    originalsFolder: originalsFolder(inStore: store, runtimeIdentifier: runtime.identifier)
                )
                return true
            } catch {
                logger.error(
                    """
                    Deploying the stored GPTK payload to runtime \(identifier, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                return false
            }
        }
    }

    /// Testable seam for ``deployStoredPayloadIfCapable()``, past the runtime
    /// capability check.
    @discardableResult
    static func deployStoredPayloadIfPresent(
        fromStore store: URL,
        intoLibraryFolder folder: URL,
        isAppleSigned: (_ code: URL, _ identifier: String) -> Bool
    ) -> Bool {
        guard storedRecord(inStore: store) != nil else { return false }
        let verdict = verifyStoredPayload(inStore: store, libraryFolder: folder, isAppleSigned: isAppleSigned)
        guard verdict == .verified else {
            logger.info("Left the stored GPTK payload undeployed: it fails the checks an import applies")
            return false
        }
        guard !holdsHandPlacedPayload(inLibraryFolder: folder, usingStore: store) else {
            logger.info("Left the GPTK payload copied into the runtime by hand in place of the stored one")
            return false
        }
        do {
            try deploy(fromStore: store, intoLibraryFolder: folder)
            return true
        } catch {
            logger.error("Deploying the stored GPTK payload failed: \(error.localizedDescription)")
            return false
        }
    }

    /// The runtime version under `folder`, or `nil` if none is readable.
    static func runtimeVersionStamp(inLibraryFolder folder: URL) -> String? {
        let plist = folder.appending(path: "WhiskyWineVersion").appendingPathExtension("plist")
        guard let info = WhiskyWineInstaller.whiskyWineInfo(at: plist) else { return nil }
        let wineBin = folder.appending(path: "Wine").appending(path: "bin")
        let wine = wineBin.appending(path: "wine64")
        let server = wineBin.appending(path: "wineserver")
        guard let plistDigest = WhiskyWineInstaller.sha256(ofFileAt: plist),
              let wineDigest = WhiskyWineInstaller.sha256(ofFileAt: wine),
              let serverDigest = WhiskyWineInstaller.sha256(ofFileAt: server)
        else { return nil }
        return "runtime:\(info.version.major).\(info.version.minor).\(info.version.patch):"
            + "\(plistDigest):\(wineDigest):\(serverDigest)"
    }

    static func runtimeVersionNumber(inLibraryFolder folder: URL) -> String? {
        let plist = folder.appending(path: "WhiskyWineVersion").appendingPathExtension("plist")
        guard let info = WhiskyWineInstaller.whiskyWineInfo(at: plist) else { return nil }
        return "\(info.version.major).\(info.version.minor).\(info.version.patch)"
    }

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
            guard let lhsDestination = try? fileManager.destinationOfSymbolicLink(atPath: lhs.path(percentEncoded: false)),
                  let rhsDestination = try? fileManager.destinationOfSymbolicLink(atPath: rhs.path(percentEncoded: false))
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
    private static func prepareOriginals(
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

    /// Testable seam for ``deployStoredPayload()``.
    static func deploy(
        fromStore store: URL,
        intoLibraryFolder folder: URL,
        originalsFolder suppliedOriginalsFolder: URL? = nil
    ) throws {
        guard storedRecord(inStore: store) != nil else {
            throw GPTKImportError.storeEmpty
        }
        let fileManager = FileManager.default
        let storeLib = store.appending(path: "lib")
        let wineLib = folder.appending(path: "Wine").appending(path: "lib")
        let peDir = wineLib.appending(path: "wine").appending(path: "x86_64-windows")
        let unixDir = wineLib.appending(path: "wine").appending(path: "x86_64-unix")
        let originals = suppliedOriginalsFolder ?? store.appending(path: "originals")
        try prepareOriginals(originalsFolder: originals, forLibraryFolder: folder)

        // A previous install leaves the interposer in the d3d12 slot, where it
        // matches neither Wine's DLL nor the store's forwarder. Clear it first
        // so the loop below sees the tree it expects and never files the
        // interposer away as if it were Wine's own builtin.
        removeVideoProcessor(fromLibraryFolder: folder, usingStore: store)

        for name in forwarderDLLNames {
            let target = peDir.appending(path: name)
            let backup = originals.appending(path: name)
            // Back up whatever Wine shipped, once; a redeploy over an existing
            // GPTK forwarder must not overwrite the original with Apple's copy.
            if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                if !fileManager.fileExists(atPath: backup.path(percentEncoded: false)),
                   !isGPTKForwarder(target, matching: storeLib) {
                    try fileManager.moveItem(at: target, to: backup)
                } else {
                    try fileManager.removeItem(at: target)
                }
            }
            try fileManager.copyItem(
                at: storeLib.appending(path: "wine").appending(path: "x86_64-windows").appending(path: name),
                to: target
            )
        }

        try fileManager.createDirectory(at: unixDir, withIntermediateDirectories: true)
        for name in unixLibraryNames {
            let link = unixDir.appending(path: name)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(
                atPath: link.path(percentEncoded: false),
                withDestinationPath: unixLinkDestination
            )
        }

        let externalDest = wineLib.appending(path: "external")
        let externalValues = try? externalDest.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if externalValues?.isSymbolicLink == true || (externalValues != nil && externalValues?.isDirectory != true) {
            throw GPTKImportError.runtimePayloadConflict(externalDest.path(percentEncoded: false))
        }
        try fileManager.createDirectory(at: externalDest, withIntermediateDirectories: true)
        let storeExternal = storeLib.appending(path: "external")
        for source in try fileManager.contentsOfDirectory(at: storeExternal, includingPropertiesForKeys: nil) {
            let destination = externalDest.appending(path: source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                guard fileSystemItemsMatch(destination, source) else {
                    throw GPTKImportError.runtimePayloadConflict(destination.path(percentEncoded: false))
                }
                continue
            }
            try fileManager.copyItem(at: source, to: destination)
        }
        // Apple's payload is in place now, which is the only moment the bridge
        // can be installed: it forwards into the payload's own shared dylib and
        // has nothing to bind to before this point.
        try installMetalFXBridge(intoLibraryFolder: folder, usingStore: store)
        // Apple's DLLs are in place now, which is the only moment the swaps can
        // be made: the runtime ships the interposers but has nothing to forward
        // into until this point. A payload from a build they were never
        // validated on is deployed without them; install checks the version.
        for interposer in interposers {
            try install(interposer, intoLibraryFolder: folder)
        }
        try installNVAPIBridge(intoLibraryFolder: folder, usingStore: store)
        logger.info("Deployed GPTK payload into the runtime tree")
    }

    /// Whether `dll` is byte-identical to the store's forwarder of the same
    /// name, so deploy never mistakes an already-deployed Apple DLL for a Wine
    /// original worth backing up and remove only deletes what it put there.
    static func isGPTKForwarder(_ dll: URL, matching storeLib: URL) -> Bool {
        let storeDLL = storeLib.appending(path: "wine").appending(path: "x86_64-windows")
            .appending(path: dll.lastPathComponent)
        return FileManager.default.contentsEqual(
            atPath: dll.path(percentEncoded: false),
            andPath: storeDLL.path(percentEncoded: false)
        )
    }
}
