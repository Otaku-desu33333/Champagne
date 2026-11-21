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

    /// Testable seam for ``deployStoredPayload()``.
    static func deploy(
        fromStore store: URL,
        intoLibraryFolder folder: URL,
        originalsFolder suppliedOriginalsFolder: URL? = nil
    ) throws {
        guard storedRecord(inStore: store) != nil else {
            throw GPTKImportError.storeEmpty
        }
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
        try deployForwarders(from: storeLib, into: peDir, originals: originals)
        try deployUnixBridges(into: unixDir)
        try deployExternalPayload(from: storeLib, into: wineLib)
        try installRuntimeBridges(into: folder, usingStore: store)
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
