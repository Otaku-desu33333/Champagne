//
//  GameCatalogEntry.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

/// Persists whether an installer was started without confirming completion.
public struct SteamSetupMarker {
    private let defaults: UserDefaults
    private static let key = "champagne.steamSetupIncomplete"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func needsSetup(clientExists: Bool) -> Bool {
        !clientExists || defaults.bool(forKey: Self.key)
    }

    public func begin() {
        defaults.set(true, forKey: Self.key)
    }

    public func complete() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// Stable storage for the Steam requests shown in discovery.
public enum SteamInstallRequests {
    public static func decode(_ text: String) -> [Int] {
        var seen = Set<Int>()
        return text.split(separator: ",").compactMap { Int($0) }
            .filter { $0 > 0 && seen.insert($0).inserted }
    }

    public static func adding(_ appID: Int, to text: String) -> String {
        var ids = decode(text)
        guard appID > 0 else { return encode(ids) }
        ids.removeAll { $0 == appID }
        ids.append(appID)
        return encode(ids)
    }

    public static func removing(_ appID: Int, from text: String) -> String {
        encode(decode(text).filter { $0 != appID })
    }

    private static func encode(_ ids: [Int]) -> String {
        ids.map(String.init).joined(separator: ",")
    }
}

/// Where a game can be acquired. The source owns its sign-in and entitlement
/// rules: Steam checks access inside its client, while a publisher page is used
/// for free games distributed outside Steam.
public enum GameInstallSource: Hashable, Sendable, Codable {
    /// Install or claim the title through the user's Steam client.
    case steam(appID: Int)
    /// Open the publisher's official download page; Champagne never mirrors the
    /// publisher's installer.
    case publisherDownloadPage(URL)
}

/// A game that can appear in discovery independently of whether it is already
/// installed in a managed Wine prefix.
public struct GameCatalogEntry: Identifiable, Hashable, Sendable, Codable {
    /// Stable catalog identifier, shared with a compatibility profile when one
    /// exists.
    public let id: String
    public let title: String
    public let subtitle: String?
    public let aliases: [String]
    /// Compatibility rating from the matching Wine profile, when one exists.
    public let compatibilityRating: CompatibilityRating?
    /// An issue recorded in the compatibility profile, if available.
    public let compatibilityIssue: String?
    /// ID of the matching compatibility profile in ``GameDBEntry``, if known.
    public let compatibilityProfileID: String?
    /// One title may be available from Steam and from an official publisher page.
    public let installSources: [GameInstallSource]

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        aliases: [String] = [],
        compatibilityRating: CompatibilityRating? = nil,
        compatibilityIssue: String? = nil,
        compatibilityProfileID: String? = nil,
        installSources: [GameInstallSource]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.aliases = aliases
        self.compatibilityRating = compatibilityRating
        self.compatibilityIssue = compatibilityIssue
        self.compatibilityProfileID = compatibilityProfileID
        self.installSources = installSources
    }
}

/// Creates a starter discovery list from the curated compatibility database.
/// It is intentionally not treated as the whole Steam catalog: it only adds
/// Steam titles for which Champagne already has a compatibility profile.
public enum GameCatalogSeed {
    public static func compatibleSteamGames(from entries: [GameDBEntry]) -> [GameCatalogEntry] {
        entries.compactMap { entry in
            guard let appID = entry.steamAppId, appID > 0 else { return nil }
            return GameCatalogEntry(
                id: entry.id,
                title: entry.title,
                subtitle: entry.subtitle,
                aliases: entry.aliases ?? [],
                compatibilityRating: entry.rating,
                compatibilityIssue: entry.knownIssues?.first(where: { $0.severity == "critical" })?.description
                    ?? entry.knownIssues?.first?.description,
                compatibilityProfileID: entry.id,
                installSources: [.steam(appID: appID)]
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
