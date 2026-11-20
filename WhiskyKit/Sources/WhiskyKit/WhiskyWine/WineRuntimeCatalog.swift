//
//  WineRuntimeCatalog.swift
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

/// A verified runtime archive published in a trusted Wine runtime repository.
public struct WineRuntimeCatalogRelease: Equatable, Identifiable, Sendable {
    /// The release title shown in the runtime picker.
    public let title: String
    /// The Git tag identifying this immutable release.
    public let tagName: String
    /// The allowlisted GitHub repository that published this runtime.
    public let repository: String
    /// Whether GitHub marks this release as a prerelease.
    public let isPrerelease: Bool
    /// The release notes page for provenance and compatibility caveats.
    public let releaseURL: URL
    /// The published Wine Libraries archive.
    public let archiveURL: URL
    /// The SHA-256 digest published by GitHub for the archive asset.
    public let archiveSHA256: String

    public var id: String { "\(repository):\(tagName)" }

    /// A safe side-by-side identifier derived from the release tag.
    public var suggestedIdentifier: String {
        let version = tagName.dropFirst().lowercased()
        let prefix = repository == WineRuntimeCatalog.champagneRepository
            ? "champagne-wine" : "wine"
        return "\(prefix)-\(version)"
    }
}

/// Errors returned by the Wine runtime catalog.
public enum WineRuntimeCatalogError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case allRepositoriesUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(
                localized: "runtime.catalog.error.invalidResponse",
                defaultValue: "The runtime catalog returned an invalid response."
            )
        case let .httpStatus(statusCode):
            String(
                localized: "runtime.catalog.error.httpStatus",
                defaultValue: "The runtime catalog returned HTTP status \(statusCode)."
            )
        case .allRepositoriesUnavailable:
            String(
                localized: "runtime.catalog.error.allRepositoriesUnavailable",
                defaultValue: "The runtime repositories could not be reached. Check your connection and try again."
            )
        }
    }
}

/// Reads public GitHub release metadata and installs Wine Libraries archives
/// from the allowlisted community and Champagne repositories only when GitHub
/// publishes a SHA-256 for the exact asset.
public enum WineRuntimeCatalog {
    static let communityRepository = "frankea/Whisky"
    static let champagneRepository = "Otaku-desu33333/Champagne"
    private static let trustedRepositories = [communityRepository, champagneRepository]

    /// Fetches installable Wine Libraries releases from the allowlisted repositories.
    public static func releases() async throws -> [WineRuntimeCatalogRelease] {
        async let communityData = try? await releaseData(from: communityRepository)
        async let champagneData = try? await releaseData(from: champagneRepository)
        let repositoryData = await [communityData, champagneData].compactMap { $0 }

        guard !repositoryData.isEmpty else {
            throw WineRuntimeCatalogError.allRepositoriesUnavailable
        }

        return try repositoryData.flatMap { repository, data in
            try decodeReleases(from: data, repository: repository)
        }
    }

    private static func releaseData(from repository: String) async throws -> (String, Data) {
        guard trustedRepositories.contains(repository),
              let apiURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")
        else {
            throw WineRuntimeCatalogError.invalidResponse
        }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Champagne", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw WineRuntimeCatalogError.invalidResponse
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw WineRuntimeCatalogError.httpStatus(response.statusCode)
        }
        return (repository, data)
    }

    /// Decodes GitHub's response and keeps only Wine runtime assets from the
    /// allowlisted repository with a published SHA-256 digest.
    static func decodeReleases(
        from data: Data,
        repository: String = communityRepository
    ) throws -> [WineRuntimeCatalogRelease] {
        guard trustedRepositories.contains(repository) else { return [] }
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return releases.compactMap { release in
            guard let title = release.name,
                  title.hasPrefix("Wine Libraries v"),
                  isSafeTag(release.tagName),
                  let releaseURL = trustedReleaseURL(
                      release.htmlURL,
                      repository: repository,
                      tagName: release.tagName
                  ),
                  let asset = release.assets.first(where: { $0.name == "Libraries.tar.gz" }),
                  asset.size > 0,
                  let digest = verifiedDigest(asset.digest),
                  let archiveURL = trustedArchiveURL(
                      asset.browserDownloadURL,
                      repository: repository,
                      tagName: release.tagName
                  )
            else { return nil }

            return WineRuntimeCatalogRelease(
                title: title,
                tagName: release.tagName,
                repository: repository,
                isPrerelease: release.isPrerelease,
                releaseURL: releaseURL,
                archiveURL: archiveURL,
                archiveSHA256: digest
            )
        }
    }

    /// Downloads, verifies and installs a catalog release without replacing
    /// the legacy runtime. Incomplete network downloads remain resumable.
    @discardableResult
    public static func install(
        _ release: WineRuntimeCatalogRelease,
        identifier: String? = nil,
        progress: @escaping @Sendable (ResumableDownloadProgress) -> Void = { _ in }
    ) async throws -> InstalledWineRuntime {
        let runtimeIdentifier = identifier ?? release.suggestedIdentifier
        let downloadFolder = WhiskyWineInstaller.runtimeDownloadsFolder
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        let archive = downloadFolder.appending(path: "runtime-\(release.archiveSHA256.prefix(20)).tar.gz")
        let isCachedArchiveValid = FileManager.default.fileExists(atPath: archive.path(percentEncoded: false))
            && WhiskyWineInstaller.integrityResult(
                forFileAt: archive,
                expectedSHA256: release.archiveSHA256
            ) == .match

        if !isCachedArchiveValid {
            if FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)) {
                ResumableDownloader.discardArtifacts(at: archive)
            }
            try await ResumableDownloader().download(
                from: release.archiveURL,
                to: archive,
                progress: progress
            )
        }

        try Task.checkCancellation()
        do {
            let runtime = try WineRuntimeStore.install(
                tarball: archive,
                identifier: runtimeIdentifier,
                expectedSHA256: release.archiveSHA256
            )
            ResumableDownloader.discardArtifacts(at: archive)
            return runtime
        } catch let error as WineRuntimeStoreError {
            switch error {
            case .archiveDigestMismatch, .archiveUnreadable, .archiveDoesNotContainRuntime:
                ResumableDownloader.discardArtifacts(at: archive)
            default:
                break
            }
            throw error
        }
    }

    private static func isSafeTag(_ tagName: String) -> Bool {
        guard tagName.hasPrefix("v"), tagName.count > 1, tagName.count <= 48 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return tagName.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func verifiedDigest(_ rawDigest: String?) -> String? {
        guard let rawDigest, rawDigest.hasPrefix("sha256:") else { return nil }
        let digest = String(rawDigest.dropFirst("sha256:".count)).lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard digest.unicodeScalars.count == 64, digest.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            return nil
        }
        return digest
    }

    private static func trustedReleaseURL(
        _ rawURL: String,
        repository: String,
        tagName: String
    ) -> URL? {
        guard let components = URLComponents(string: rawURL),
              isTrustedGitHubURL(components),
              components.path == "/\(repository)/releases/tag/\(tagName)"
        else { return nil }
        return components.url
    }

    private static func trustedArchiveURL(
        _ rawURL: String,
        repository: String,
        tagName: String
    ) -> URL? {
        guard let components = URLComponents(string: rawURL),
              isTrustedGitHubURL(components),
              components.path == "/\(repository)/releases/download/\(tagName)/Libraries.tar.gz"
        else { return nil }
        return components.url
    }

    private static func isTrustedGitHubURL(_ components: URLComponents) -> Bool {
        components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "github.com"
            && components.user == nil
            && components.password == nil
            && components.port == nil
            && components.query == nil
            && components.fragment == nil
    }
}

private struct GitHubRelease: Decodable {
    let name: String?
    let tagName: String
    let htmlURL: String
    let isPrerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case name
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case isPrerelease = "prerelease"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String
    let digest: String?
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
        case size
    }
}
