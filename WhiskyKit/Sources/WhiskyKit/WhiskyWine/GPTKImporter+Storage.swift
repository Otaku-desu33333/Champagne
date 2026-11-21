//
//  GPTKImporter+Storage.swift
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

extension GPTKImporter {
    @discardableResult
    public static func importPayload(_ payload: GPTKPayload) throws -> GPTKStoreRecord {
        try withFileOperationLock {
            let store = storeFolder
            var runtimes = deployedRuntimes(
                from: WineRuntimeStore.installedRuntimes(),
                usingStore: store
            )
            if !runtimes.contains(where: { $0.identifier == WineRuntimeStore.defaultRuntimeIdentifier }),
               let defaultRuntime = WineRuntimeStore.runtime(identifier: WineRuntimeStore.defaultRuntimeIdentifier),
               defaultRuntime.versionInfo.gptkCapable == true {
                runtimes.insert(defaultRuntime, at: 0)
            }
            let record = try importPayload(
                payload,
                intoStore: store,
                revalidatingWith: isAppleSigned(_:identifier:),
                beforeReplacingStoredPayload: {
                    guard storedRecord(inStore: store) != nil else { return }
                    try removeDeployedPayloadsFromAllRuntimes()
                }
            )
            try redeployStoredPayloads(to: runtimes, usingStore: store) { runtime in
                try deployStoredPayload(forRuntime: runtime.identifier)
            }
            return record
        }
    }

    /// Testable seam for ``importPayload(_:)``.
    ///
    /// - Parameter isAppleSigned: the verifier the staged copy is validated
    ///   with. Tests leave it out to import fixtures that are not real code
    ///   objects, which skips that second validation.
    @discardableResult
    static func importPayload(
        _ payload: GPTKPayload,
        intoStore store: URL,
        revalidatingWith isAppleSigned: ((_ code: URL, _ identifier: String) -> Bool)? = nil,
        beforeReplacingStoredPayload: (() throws -> Void)? = nil,
        afterReplacingStoredPayload: ((GPTKStoreRecord) throws -> Void)? = nil
    ) throws -> GPTKStoreRecord {
        try withFileOperationLock {
            let fileManager = FileManager.default
            let libDest = store.appending(path: "lib")
            let staging = store.appending(path: "lib.staging")

            try fileManager.createDirectory(at: store, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: staging)
            var version = payload.version
            do {
                // The folder a link points to, not the link: a staged link would
                // leave the store pointing at the source, and every later deploy
                // would copy whatever the source holds by then.
                try fileManager.copyItem(at: payload.libRoot.resolvingSymlinksInPath(), to: staging)
                try linkUnixBridges(inPayload: staging)
                if let isAppleSigned {
                    version = try validatePayload(at: staging, isAppleSigned: isAppleSigned).version
                }
                try beforeReplacingStoredPayload?()
                // attributesOfItem does not follow a link, so a lib left behind as
                // a dangling link is replaced too; fileExists would not see it.
                if (try? fileManager.attributesOfItem(atPath: libDest.path(percentEncoded: false))) != nil {
                    try fileManager.removeItem(at: libDest)
                }
                try fileManager.moveItem(at: staging, to: libDest)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }

            let record = GPTKStoreRecord(gptkVersion: version, importedAt: Date())
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(record).write(to: recordURL(inStore: store))
            // Validated above, as it sits in the store now, so the first deploy
            // does not check it again.
            if isAppleSigned != nil {
                stampStoreVerified(inStore: store)
            }
            try afterReplacingStoredPayload?(record)
            logger.info("Imported GPTK payload \(record.gptkVersion, privacy: .public) into store")
            return record
        }
    }

    static func deployedRuntimes(
        from runtimes: [InstalledWineRuntime],
        usingStore store: URL
    ) -> [InstalledWineRuntime] {
        runtimes.filter {
            $0.versionInfo.gptkCapable == true
                && isStorePayloadDeployed(inLibraryFolder: $0.libraryFolder, usingStore: store)
        }
    }

    static func redeployStoredPayloads(
        to runtimes: [InstalledWineRuntime],
        usingStore store: URL,
        deploy: (InstalledWineRuntime) throws -> Void
    ) throws {
        guard storedRecord(inStore: store) != nil else { throw GPTKImportError.storeEmpty }
        var failures: [(String, String)] = []
        for runtime in runtimes where runtime.versionInfo.gptkCapable == true {
            do {
                try deploy(runtime)
            } catch {
                failures.append((runtime.identifier, error.localizedDescription))
                logger.error(
                    """
                    GPTK redeployment to runtime \(runtime.identifier, privacy: .public) failed: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
        if let (identifier, reason) = failures.first {
            throw GPTKImportError.runtimeRedeploymentFailed(identifier: identifier, reason: reason)
        }
    }

    /// Recreates the unix bridge names in the payload at `libRoot` as symlinks
    /// to its shared library.
    private static func linkUnixBridges(inPayload libRoot: URL) throws {
        let fileManager = FileManager.default
        let unixDir = libRoot.appending(path: "wine").appending(path: "x86_64-unix")
        try fileManager.createDirectory(at: unixDir, withIntermediateDirectories: true)
        for name in unixLibraryNames {
            let link = unixDir.appending(path: name)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(
                atPath: link.path(percentEncoded: false),
                withDestinationPath: unixLinkDestination
            )
        }
    }
}
