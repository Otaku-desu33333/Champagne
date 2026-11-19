//
//  WineRuntimeCatalogTests.swift
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
import Testing
@testable import WhiskyKit

struct WineRuntimeCatalogTests {
    @Test("Only official Wine runtime archives with a published SHA-256 enter the catalog")
    func catalogFiltersReleaseAssets() throws {
        let digest = String(repeating: "a", count: 64)
        let data = try JSONSerialization.data(withJSONObject: runtimeReleases(digest: digest))
        let releases = try WineRuntimeCatalog.decodeReleases(from: data)

        #expect(releases.count == 1)
        #expect(releases.first?.tagName == "v4.6.4-beta.1")
        #expect(releases.first?.repository == WineRuntimeCatalog.communityRepository)
        #expect(releases.first?.id == "frankea/Whisky:v4.6.4-beta.1")
        #expect(releases.first?.isPrerelease == true)
        #expect(releases.first?.archiveSHA256 == digest)
        #expect(releases.first?.suggestedIdentifier == "wine-4.6.4-beta.1")
    }

    @Test("Champagne runtime releases are kept separate from community releases")
    func champagneReleaseGetsNamespacedIdentifier() throws {
        let repository = WineRuntimeCatalog.champagneRepository
        let digest = String(repeating: "b", count: 64)
        let release = self.release(
            name: "Wine Libraries v0.2.0",
            tag: "v0.2.0",
            prerelease: false,
            archiveURL: "https://github.com/\(repository)/releases/download/v0.2.0/Libraries.tar.gz",
            digest: digest,
            repository: repository
        )
        let data = try JSONSerialization.data(withJSONObject: [release])
        let catalog = try WineRuntimeCatalog.decodeReleases(from: data, repository: repository)

        #expect(catalog.count == 1)
        #expect(catalog.first?.repository == repository)
        #expect(catalog.first?.id == "Otaku-desu33333/Champagne:v0.2.0")
        #expect(catalog.first?.suggestedIdentifier == "champagne-wine-0.2.0")
    }

    @Test("A runtime asset must belong to the repository that published its release")
    func catalogRejectsCrossRepositoryAssetURL() throws {
        let release = self.release(
            name: "Wine Libraries v0.2.0",
            tag: "v0.2.0",
            prerelease: false,
            archiveURL: "https://github.com/frankea/Whisky/releases/download/v0.2.0/Libraries.tar.gz",
            digest: String(repeating: "c", count: 64),
            repository: WineRuntimeCatalog.champagneRepository
        )
        let data = try JSONSerialization.data(withJSONObject: [release])

        #expect(
            try WineRuntimeCatalog.decodeReleases(
                from: data,
                repository: WineRuntimeCatalog.champagneRepository
            ).isEmpty
        )
    }

    private func runtimeReleases(digest: String) -> [[String: Any]] {
        let repository = "https://github.com/frankea/Whisky"
        return [
            release(
                name: "Wine Libraries v4.6.4-beta.1 (GPTK, Wine 11.16)",
                tag: "v4.6.4-beta.1",
                prerelease: true,
                archiveURL: "\(repository)/releases/download/v4.6.4-beta.1/Libraries.tar.gz",
                digest: digest,
                repository: WineRuntimeCatalog.communityRepository
            ),
            release(
                name: "Whisky 3.9.2",
                tag: "v3.9.2",
                prerelease: false,
                archiveURL: "\(repository)/releases/download/v3.9.2/Libraries.tar.gz",
                digest: digest,
                repository: WineRuntimeCatalog.communityRepository
            ),
            release(
                name: "Wine Libraries v5.0",
                tag: "v5.0",
                prerelease: false,
                archiveURL: "https://example.com/Libraries.tar.gz",
                digest: digest,
                repository: WineRuntimeCatalog.communityRepository
            ),
            release(
                name: "Wine Libraries v4.0.0-beta.1",
                tag: "v4.0.0-beta.1",
                prerelease: true,
                archiveURL: "\(repository)/releases/download/v4.0.0-beta.1/Libraries.tar.gz",
                digest: nil,
                repository: WineRuntimeCatalog.communityRepository
            )
        ]
    }

    private func release(
        name: String,
        tag: String,
        prerelease: Bool,
        archiveURL: String,
        digest: String?,
        repository: String = WineRuntimeCatalog.communityRepository
    ) -> [String: Any] {
        let digestValue: Any = if let digest {
            "sha256:\(digest)"
        } else {
            NSNull()
        }
        return [
            "name": name,
            "tag_name": tag,
            "html_url": "https://github.com/\(repository)/releases/tag/\(tag)",
            "prerelease": prerelease,
            "assets": [[
                "name": "Libraries.tar.gz",
                "browser_download_url": archiveURL,
                "digest": digestValue,
                "size": 1_024
            ]]
        ]
    }
}
