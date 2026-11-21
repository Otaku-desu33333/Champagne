//
//  DistributionConfig.swift
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

public enum DistributionConfig {
    /// Base URL for GitHub Pages distribution
    public static let baseURL = "https://otaku-desu33333.github.io/Champagne"

    /// Public Wine runtime manifest maintained with the verified upstream archives.
    public static let versionPlistURL = "https://raw.githubusercontent.com/frankea/Whisky/main/dist/pages/WhiskyWineVersion.plist"

    /// Base URL for the Wine Libraries archives whose digest the manifest publishes.
    public static let releasesBaseURL = "https://github.com/frankea/Whisky/releases/download"

    /// Canonical Champagne appcast location. Sparkle remains disabled until the
    /// app contains its signing public key and releases are published.
    public static let appcastURL = "https://raw.githubusercontent.com/Otaku-desu33333/Champagne/main/appcast.xml"

    /// Constructs the download URL for Wine Libraries from GitHub Releases
    /// - Parameter version: The version string (e.g., "2.5.0")
    /// - Returns: The full URL to download Libraries.tar.gz from GitHub Releases
    public static func librariesURL(version: String) -> String {
        "\(releasesBaseURL)/v\(version)/Libraries.tar.gz"
    }
}
