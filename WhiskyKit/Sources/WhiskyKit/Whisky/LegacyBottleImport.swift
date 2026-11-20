//
//  LegacyBottleImport.swift
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

/// Finds bottles from earlier Whisky installations after Champagne's bundle ID
/// change. Discovered bottles are referenced in place; their data is not moved
/// or copied.
public enum LegacyBottleImport {
    private static let logger = Logger(
        subsystem: Bundle.champagneBundleIdentifier,
        category: "LegacyBottleImport"
    )

    /// Bundle identifier of the original Whisky app.
    public static let legacyBundleIdentifier = "com.isaacmarovitz.Whisky"
    /// Bundle identifier used by the preceding Whisky-branded Champagne build.
    public static let previousBundleIdentifier = "com.franke.Whisky"

    /// `~/Library/Containers/com.isaacmarovitz.Whisky`.
    public static var legacyContainerDirectory: URL {
        containerDirectory(for: legacyBundleIdentifier)
    }

    /// The previous Champagne identity's bottle container.
    public static var previousContainerDirectory: URL {
        containerDirectory(for: previousBundleIdentifier)
    }

    private static var sourceContainers: [URL] {
        [legacyContainerDirectory, previousContainerDirectory]
    }

    private static func containerDirectory(for bundleIdentifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Containers")
            .appending(path: bundleIdentifier)
    }

    /// Minimal decode of the original app's bottle registry. Same plist shape as
    /// ``BottleData`` — we only need the registered paths.
    private struct LegacyRegistry: Decodable {
        var paths: [URL]
    }

    /// Whether any earlier Whisky container exists. An explicit URL keeps this
    /// check convenient for tests and callers inspecting one source.
    public static func legacyContainerExists(at container: URL? = nil) -> Bool {
        (container.map { [$0] } ?? sourceContainers).contains {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    /// URLs of original-app bottles that are valid (contain a `Metadata.plist`) and are
    /// not already registered in `existingPaths`.
    ///
    /// Reads each source's `BottleVM.plist` registry and scans its default
    /// `Bottles` directory as a fallback. When no container is specified, both
    /// the original Whisky app and the previous Champagne bundle ID are checked.
    ///
    /// - Parameters:
    ///   - legacyContainer: one source container to inspect, or `nil` to inspect all known sources.
    ///   - existingPaths: bottle paths already registered in Champagne, to avoid duplicates.
    public static func importableBottleURLs(
        legacyContainer: URL? = nil,
        existingPaths: [URL]
    ) -> [URL] {
        discoveredBottleURLs(legacyContainer: legacyContainer, existingPaths: existingPaths).map(\.url)
    }

    private static func discoveredBottleURLs(
        legacyContainer: URL?,
        existingPaths: [URL]
    ) -> [(url: URL, container: URL)] {
        let existing = Set(existingPaths.map(\.standardizedFileURL))
        var candidates: [(url: URL, container: URL)] = []

        for container in legacyContainer.map({ [$0] }) ?? sourceContainers {
            let registryURL = container.appending(path: "BottleVM").appendingPathExtension("plist")
            if let data = try? Data(contentsOf: registryURL),
               let registry = try? PropertyListDecoder().decode(LegacyRegistry.self, from: data) {
                candidates.append(contentsOf: registry.paths.map { ($0, container) })
            }

            // Scan the default Bottles directory in case its registry is missing or stale.
            let bottlesDir = container.appending(path: "Bottles")
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: bottlesDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                candidates.append(contentsOf: entries.map { ($0, container) })
            }
        }

        var seen = Set<URL>()
        var result: [(url: URL, container: URL)] = []
        for (candidate, container) in candidates {
            let standardized = candidate.standardizedFileURL
            guard !existing.contains(standardized), seen.insert(standardized).inserted else { continue }
            guard isBottle(at: standardized) else { continue }
            result.append((standardized, container))
        }

        logger.info("Discovered \(result.count) importable legacy bottle(s)")
        return result.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// An importable original-app bottle, with the display name read from its settings.
    public struct DiscoveredBottle: Identifiable, Hashable, Sendable {
        /// The bottle's directory URL (also its identity).
        public let url: URL
        /// The bottle's display name, read from its settings (falls back to the directory name).
        public let name: String
        /// The earlier application installation that owns the bottle.
        public let sourceName: String
        public var id: URL {
            url
        }
    }

    /// Like ``importableBottleURLs(legacyContainer:existingPaths:)`` but also reads each bottle's
    /// display name. Names are read **non-destructively** (see ``readOnlyName(at:)``) — discovery
    /// must never mutate the original app's bottles.
    public static func importableBottles(
        legacyContainer: URL? = nil,
        existingPaths: [URL]
    ) -> [DiscoveredBottle] {
        discoveredBottleURLs(legacyContainer: legacyContainer, existingPaths: existingPaths).map { entry in
            let sourceName = entry.container.lastPathComponent == previousBundleIdentifier
                ? "Previous Whisky installation" : "Original Whisky installation"
            return DiscoveredBottle(
                url: entry.url,
                name: readOnlyName(at: entry.url) ?? entry.url.lastPathComponent,
                sourceName: sourceName
            )
        }
    }

    /// Reads a bottle's display name from its `Metadata.plist` **without writing anything**.
    ///
    /// This decodes `BottleSettings` directly via `PropertyListDecoder` (whose `init(from:)` is
    /// pure). It deliberately does **not** use `BottleSettings.decode(from:)` or construct a
    /// `Bottle`: both of those rewrite the metadata file when the bottle's file/wine version
    /// differs from the current app's defaults — which a bottle from the original app almost
    /// always does — and that would silently mutate the user's original bottles just by opening
    /// the migration sheet. Returns `nil` if the metadata is missing or undecodable.
    private static func readOnlyName(at bottleURL: URL) -> String? {
        let metadata = bottleURL.appending(path: "Metadata").appendingPathExtension("plist")
        guard let data = try? Data(contentsOf: metadata),
              let settings = try? PropertyListDecoder().decode(BottleSettings.self, from: data)
        else { return nil }
        return settings.name
    }

    /// A directory is treated as a bottle when it contains a `Metadata.plist`, the marker
    /// ``Bottle`` and ``BottleData`` use to recognise a real bottle on disk.
    private static func isBottle(at url: URL) -> Bool {
        let metadata = url.appending(path: "Metadata").appendingPathExtension("plist")
        return FileManager.default.fileExists(atPath: metadata.path(percentEncoded: false))
    }
}
