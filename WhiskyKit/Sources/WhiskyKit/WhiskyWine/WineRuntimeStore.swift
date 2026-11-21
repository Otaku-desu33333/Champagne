//
//  WineRuntimeStore.swift
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

private let runtimeStoreLogger = Logger(
    subsystem: Bundle.champagneBundleIdentifier,
    category: "WineRuntimeStore"
)

/// A Wine runtime installed beside the legacy default runtime.
///
/// `libraryFolder` is the folder that contains `Wine/`, `DXVK/`, and
/// `WhiskyWineVersion.plist`. The legacy runtime remains at the existing
/// `Libraries/` path; named runtimes live under `Runtimes/<identifier>/`.
public struct InstalledWineRuntime: Identifiable {
    /// Stable local identifier assigned when the runtime is installed.
    public let identifier: String
    /// The runtime's self-contained libraries folder.
    public let libraryFolder: URL
    /// Metadata shipped with the runtime archive.
    public let versionInfo: WhiskyWineVersion

    public var id: String { identifier }
}

/// Errors raised while managing named Wine runtime installations.
public enum WineRuntimeStoreError: LocalizedError, Equatable {
    case invalidIdentifier(String)
    case defaultRuntimeIsReserved
    case runtimeAlreadyExists(String)
    case runtimeNotInstalled(String)
    case runtimeSelectionLocked
    case runtimeNotGPTKCapable(String)
    case archiveDigestMismatch(actual: String)
    case archiveUnreadable
    case archiveDoesNotContainRuntime

    public var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(identifier):
            String(
                localized: "runtime.store.invalidIdentifier",
                defaultValue: "Invalid ID ‘\(identifier)’. Use lowercase letters, digits, and . _ - only."
            )
        case .defaultRuntimeIsReserved:
            String(
                localized: "runtime.store.defaultIdentifierReserved",
                defaultValue: "The identifier ‘default’ is reserved for the existing Wine runtime."
            )
        case let .runtimeAlreadyExists(identifier):
            String(
                localized: "runtime.store.alreadyExists",
                defaultValue: "A runtime named ‘\(identifier)’ is already installed."
            )
        case let .runtimeNotInstalled(identifier):
            String(
                localized: "runtime.store.notInstalled",
                defaultValue: "Runtime ‘\(identifier)’ is not installed. Install it or choose another."
            )
        case .runtimeSelectionLocked:
            String(
                localized: "runtime.store.selectionLocked",
                defaultValue: "The Wine runtime cannot be changed while this bottle is busy. Try again when it is idle."
            )
        case let .runtimeNotGPTKCapable(identifier):
            String(
                localized: "runtime.store.gptkUnsupported",
                defaultValue: "The Wine runtime ‘\(identifier)’ cannot run the imported GPTK payload."
            )
        case let .archiveDigestMismatch(actual):
            String(
                localized: "runtime.store.digestMismatch",
                defaultValue: "The runtime archive did not match its expected SHA-256 digest. Actual digest: \(actual)"
            )
        case .archiveUnreadable:
            String(
                localized: "runtime.store.archiveUnreadable",
                defaultValue: "The runtime archive could not be read for integrity verification."
            )
        case .archiveDoesNotContainRuntime:
            String(
                localized: "runtime.store.archiveInvalid",
                defaultValue: "The archive did not contain a complete Wine runtime."
            )
        }
    }
}

/// Side-by-side storage for Wine runtime archives.
///
/// Archives are digest-checked when a digest is supplied, extracted to a
/// staging directory, validated, and only then moved into their final slot.
/// Bottle settings select a runtime by identifier; older bottles keep using
/// the existing `Libraries/` runtime. Named installs never replace it.
public enum WineRuntimeStore {
    /// Identifier returned for the existing, single-path Wine installation.
    public static let defaultRuntimeIdentifier = "default"

    /// Root folder for named runtimes.
    public static var runtimesDirectory: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "Runtimes")
    }

    /// Lists the default runtime and every valid named runtime found on disk.
    /// Invalid or partial folders are ignored rather than presented as usable.
    public static func installedRuntimes() -> [InstalledWineRuntime] {
        var installed: [InstalledWineRuntime] = []

        if let runtime = makeRecord(
            identifier: defaultRuntimeIdentifier,
            libraryFolder: WhiskyWineInstaller.libraryFolder
        ) {
            installed.append(runtime)
        }

        installed += installedNamedRuntimes(inRuntimesDirectory: runtimesDirectory)

        return installed.sorted { lhs, rhs in
            if lhs.identifier == defaultRuntimeIdentifier { return true }
            if rhs.identifier == defaultRuntimeIdentifier { return false }
            return lhs.identifier.localizedStandardCompare(rhs.identifier) == .orderedAscending
        }
    }

    /// Lists only complete named runtimes under a real runtime root.
    static func installedNamedRuntimes(inRuntimesDirectory runtimeRoot: URL) -> [InstalledWineRuntime] {
        guard isRealDirectory(runtimeRoot),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: runtimeRoot,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        var installed: [InstalledWineRuntime] = []
        for entry in entries {
            let identifier = entry.lastPathComponent
            guard (try? validatedIdentifier(identifier)) != nil,
                  let runtime = makeRecord(identifier: identifier, libraryFolder: entry)
            else { continue }
            installed.append(runtime)
        }
        return installed
    }

    /// Returns an installed runtime by stable identifier.
    public static func runtime(identifier: String) -> InstalledWineRuntime? {
        guard let identifier = try? validatedIdentifier(identifier) else { return nil }
        guard let folder = libraryFolder(identifier: identifier) else { return nil }
        return makeRecord(identifier: identifier, libraryFolder: folder)
    }

    /// Resolves the storage path for a runtime identifier without requiring
    /// that the runtime is currently installed. Launch code should use
    /// ``runtime(identifier:)`` and fail closed; command preview code can use
    /// this path to render the command the selected runtime would use.
    public static func libraryFolder(identifier: String) -> URL? {
        guard let identifier = try? validatedIdentifier(identifier) else { return nil }
        return identifier == defaultRuntimeIdentifier
            ? WhiskyWineInstaller.libraryFolder
            : runtimesDirectory.appending(path: identifier)
    }

    /// Resolves the runtime selected by a bottle, failing when its selection is
    /// invalid or no longer installed.
    @MainActor
    public static func selectedRuntime(for bottle: Bottle) throws -> InstalledWineRuntime {
        let identifier = bottle.settings.wineRuntimeIdentifier ?? defaultRuntimeIdentifier
        guard libraryFolder(identifier: identifier) != nil else {
            throw WineRuntimeStoreError.invalidIdentifier(identifier)
        }
        guard let runtime = runtime(identifier: identifier) else {
            throw WineRuntimeStoreError.runtimeNotInstalled(identifier)
        }
        return runtime
    }

    /// Assigns an installed runtime to a bottle. Passing `nil` restores the
    /// legacy default runtime used by existing bottles.
    @MainActor
    public static func select(_ identifier: String?, for bottle: Bottle) throws {
        guard !bottle.inFlight else { throw WineRuntimeStoreError.runtimeSelectionLocked }
        let selectedIdentifier = identifier ?? defaultRuntimeIdentifier
        guard libraryFolder(identifier: selectedIdentifier) != nil else {
            throw WineRuntimeStoreError.invalidIdentifier(selectedIdentifier)
        }
        guard let runtime = runtime(identifier: selectedIdentifier) else {
            throw WineRuntimeStoreError.runtimeNotInstalled(selectedIdentifier)
        }
        var settings = bottle.settings
        settings.wineRuntimeIdentifier = selectedIdentifier == defaultRuntimeIdentifier
            ? nil : selectedIdentifier
        settings.wineVersion = runtime.versionInfo.version
        bottle.settings = settings
    }

    /// Installs a named runtime without replacing the current default runtime.
    ///
    /// The archive is expected to contain a top-level `Libraries/` directory,
    /// matching the existing Wine runtime format. Supplying `expectedSHA256`
    /// enables a streaming integrity check before extraction. The final slot is
    /// immutable: install an updated archive under a new identifier, then
    /// assign it to a bottle with ``select(_:for:)``.
    ///
    /// - Parameters:
    ///   - tarball: A local Wine runtime archive.
    ///   - identifier: A unique, lowercase identifier such as `wine-11` or `gptk4-wine`.
    ///   - expectedSHA256: Optional expected archive digest from trusted release metadata.
    /// - Returns: The validated runtime record after installation.
    @discardableResult
    public static func install(
        tarball: URL,
        identifier: String,
        expectedSHA256: String? = nil
    ) throws -> InstalledWineRuntime {
        try install(
            tarball: tarball,
            identifier: identifier,
            expectedSHA256: expectedSHA256,
            inRuntimesDirectory: runtimesDirectory
        )
    }

    /// Isolated runtime-root seam for install validation and recovery tests.
    static func install(
        tarball: URL,
        identifier: String,
        expectedSHA256: String? = nil,
        inRuntimesDirectory runtimeRoot: URL
    ) throws -> InstalledWineRuntime {
        let identifier = try validatedIdentifier(identifier)
        guard identifier != defaultRuntimeIdentifier else {
            throw WineRuntimeStoreError.defaultRuntimeIsReserved
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: tarball.path(percentEncoded: false)) else {
            throw WhiskyWineInstallError.tarballNotFound
        }

        if let expectedSHA256 {
            switch WhiskyWineInstaller.integrityResult(forFileAt: tarball, expectedSHA256: expectedSHA256) {
            case .match:
                break
            case let .mismatch(actual):
                throw WineRuntimeStoreError.archiveDigestMismatch(actual: actual)
            case .unreadable:
                throw WineRuntimeStoreError.archiveUnreadable
            }
        }

        guard !isIdentifierOccupied(identifier, inRuntimesDirectory: runtimeRoot) else {
            throw WineRuntimeStoreError.runtimeAlreadyExists(identifier)
        }
        if pathExistsIncludingSymlinks(runtimeRoot), !isRealDirectory(runtimeRoot) {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: runtimeRoot.path])
        }
        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        guard isRealDirectory(runtimeRoot) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: runtimeRoot.path])
        }
        let destination = runtimeRoot.appending(path: identifier)

        let staging = runtimeRoot.appending(path: ".install-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }

        try WhiskyWineInstaller.install(tarball: tarball, into: staging)
        let stagedLibraries = staging.appending(path: "Libraries")
        guard makeRecord(identifier: identifier, libraryFolder: stagedLibraries) != nil else {
            throw WineRuntimeStoreError.archiveDoesNotContainRuntime
        }

        // Staging and destination are on the same volume, so this final rename
        // exposes only a complete runtime and leaves the legacy runtime alone.
        try fileManager.moveItem(at: stagedLibraries, to: destination)
        guard let installed = makeRecord(identifier: identifier, libraryFolder: destination) else {
            try? fileManager.removeItem(at: destination)
            throw WineRuntimeStoreError.archiveDoesNotContainRuntime
        }

        let version = String(describing: installed.versionInfo.version)
        runtimeStoreLogger.info(
            "Installed Wine runtime \(identifier, privacy: .public) version \(version, privacy: .public)"
        )
        return installed
    }

    private static func makeRecord(
        identifier: String,
        libraryFolder: URL
    ) -> InstalledWineRuntime? {
        if identifier != defaultRuntimeIdentifier, !isRealDirectory(libraryFolder) {
            return nil
        }
        guard WhiskyWineInstaller.isRuntimePresent(inLibraryFolder: libraryFolder) else { return nil }
        if identifier != defaultRuntimeIdentifier, !isCompleteNamedRuntime(inLibraryFolder: libraryFolder) {
            return nil
        }
        let versionPlist = libraryFolder.appending(path: "WhiskyWineVersion").appendingPathExtension("plist")
        guard let versionInfo = WhiskyWineInstaller.whiskyWineInfo(at: versionPlist) else { return nil }
        return InstalledWineRuntime(identifier: identifier, libraryFolder: libraryFolder, versionInfo: versionInfo)
    }

    /// Named runtime roots must be actual directories. Following a root
    /// symlink would let an imported or manually placed entry resolve outside
    /// Champagne's managed runtime slot; the legacy default keeps its historic
    /// presence check for compatibility.
    private static func isRealDirectory(_ folder: URL) -> Bool {
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Named archives are accepted only when they contain the binaries and
    /// graphics payloads Champagne's launch paths require. The legacy default
    /// keeps its older presence check so pre-existing installs remain visible.
    private static func isCompleteNamedRuntime(inLibraryFolder folder: URL) -> Bool {
        let fileManager = FileManager.default
        let wineBin = folder.appending(path: "Wine").appending(path: "bin")
        let wineserver = wineBin.appending(path: "wineserver")
        let dxvk = folder.appending(path: "DXVK")
        let requiredDLLs = [
            dxvk.appending(path: "x64").appending(path: "d3d11.dll"),
            dxvk.appending(path: "x32").appending(path: "d3d11.dll")
        ]
        return fileManager.isExecutableFile(atPath: wineBin.appending(path: "wine64").path(percentEncoded: false))
            && fileManager.isExecutableFile(atPath: wineserver.path(percentEncoded: false))
            && requiredDLLs.allSatisfy { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Whether an identifier is invalid or already has a runtime directory on disk.
    public static func isIdentifierOccupied(_ identifier: String) -> Bool {
        isIdentifierOccupied(identifier, inRuntimesDirectory: runtimesDirectory)
    }

    static func isIdentifierOccupied(_ identifier: String, inRuntimesDirectory runtimeRoot: URL) -> Bool {
        guard (try? validatedIdentifier(identifier)) != nil else { return true }
        if identifier == defaultRuntimeIdentifier {
            return pathExistsIncludingSymlinks(WhiskyWineInstaller.libraryFolder)
        }
        if pathExistsIncludingSymlinks(runtimeRoot), !isRealDirectory(runtimeRoot) {
            return true
        }
        return pathExistsIncludingSymlinks(runtimeRoot.appending(path: identifier))
    }

    private static func pathExistsIncludingSymlinks(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    static func validatedIdentifier(_ identifier: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        let firstScalar = identifier.unicodeScalars.first
        let startsAlphanumeric = firstScalar.map {
            $0.isASCII && (CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0))
        } ?? false
        let isValid = !identifier.isEmpty
            && identifier.count <= 64
            && identifier == identifier.lowercased()
            && startsAlphanumeric
            && identifier.unicodeScalars.allSatisfy(allowed.contains)
            && !identifier.contains("..")
            && !identifier.hasSuffix(".")

        guard isValid else {
            throw WineRuntimeStoreError.invalidIdentifier(identifier)
        }
        return identifier
    }
}
