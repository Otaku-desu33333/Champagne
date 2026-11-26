//
//  SteamCMDDownloadSession.swift
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

import AppKit
import Combine
import Darwin
import Foundation

/// A Steam authentication prompt raised by SteamCMD while Champagne owns the install flow.
public enum SteamCMDAuthenticationPrompt: String, Identifiable, Equatable, Sendable {
    case password
    case authenticatorCode

    public var id: String { rawValue }
}

/// Progress reported by SteamCMD while it downloads a Windows game depot.
public struct SteamCMDDownloadProgress: Equatable, Sendable {
    public let downloadedBytes: UInt64
    public let totalBytes: UInt64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(totalBytes))
    }
}

/// Runs Valve's macOS SteamCMD as Champagne's download engine.
///
/// Passwords and authenticator codes are sent over the child process's standard input;
/// they are never included in the SteamCMD command line or written to Champagne logs.
@MainActor
public final class SteamCMDDownloadSession: ObservableObject {
    public static let shared = SteamCMDDownloadSession()

    @Published public private(set) var status: String?
    @Published public private(set) var progress: SteamCMDDownloadProgress?
    @Published public private(set) var authenticationPrompt: SteamCMDAuthenticationPrompt?
    @Published public private(set) var isRunning = false
    @Published public private(set) var didComplete = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var generatedManifestURL: URL?
    @Published public private(set) var appID: Int?

    public var canCancel: Bool { process?.isRunning == true }

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipes: [Pipe] = []
    private var bufferedOutput = ""
    private var promptScanBuffer = ""
    private var sawSuccess = false
    private var userCancelled = false
    private var targetDirectory: URL?
    private var gameTitle: String?
    private var gameBottleURL: URL?
    private var appTerminationObserver: NSObjectProtocol?

    public init() {
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    /// Starts a direct Windows depot download in the managed Steam library.
    ///
    /// The Steam account name is public account metadata; secrets are requested only
    /// after SteamCMD starts and prompts for them.
    public func start(appID: Int, title: String, accountName: String, bottleURL: URL) async throws {
        guard appID > 0 else { throw SteamCMDDownloadError.invalidAppID }
        let username = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !username.contains(where: \.isNewline) else {
            throw SteamCMDDownloadError.invalidAccountName
        }
        guard !isRunning else { return }
        guard let installDirectory = SteamLibrary.directInstallURL(
            appID: appID, title: title, bottleURL: bottleURL
        ) else { throw SteamCMDDownloadError.invalidInstallLocation }

        reset()
        self.appID = appID
        gameTitle = title
        gameBottleURL = bottleURL
        targetDirectory = installDirectory
        status = "Preparing your download…"

        let installation = try await SteamCMDBootstrap.prepare()
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let process = Process()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installation.scriptURL.path] + [
            "+@ShutdownOnFailedCommand", "1",
            "+@sSteamCmdForcePlatformType", "windows",
            "+force_install_dir", installDirectory.path,
            "+login", username,
            "+app_update", String(appID), "validate",
            "+quit"
        ]
        process.currentDirectoryURL = installation.rootURL
        var environment = ProcessInfo.processInfo.environment
        // Keep SteamCMD's local configuration and remembered login token in a private
        // Champagne-owned directory, away from the user's native Steam installation.
        let privateHome = installation.rootURL.appending(path: "AccountHome")
        try FileManager.default.createDirectory(
            at: privateHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateHome.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installation.rootURL.path)
        environment["HOME"] = privateHome.path
        process.environment = environment
        process.standardInput = stdin

        self.process = process
        inputPipe = stdin
        isRunning = true
        status = "Connecting to Steam…"

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        outputPipes = [stdout, stderr]
        attachReader(to: stdout)
        attachReader(to: stderr)

        process.terminationHandler = { [weak self] terminatedProcess in
            let code = terminatedProcess.terminationStatus
            Task { @MainActor [weak self] in
                self?.finish(exitCode: code)
            }
        }

        do {
            try process.run()
        } catch {
            isRunning = false
            self.process = nil
            inputPipe = nil
            status = nil
            throw error
        }
    }

    /// Answers SteamCMD's current password or two-factor prompt.
    public func submitAuthenticationResponse(_ response: String) throws {
        guard authenticationPrompt != nil, let inputPipe else {
            throw SteamCMDDownloadError.noAuthenticationPrompt
        }
        let answer = authenticationPrompt == .password
            ? response
            : response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, !answer.contains(where: \.isNewline) else {
            throw SteamCMDDownloadError.invalidAuthenticationResponse
        }
        try inputPipe.fileHandleForWriting.write(contentsOf: Data((answer + "\n").utf8))
        authenticationPrompt = nil
        promptScanBuffer = ""
        status = "Signing in to Steam…"
    }

    public func cancel() {
        authenticationPrompt = nil
        guard let process, process.isRunning else { return }
        userCancelled = true
        Self.terminateDescendants(of: process.processIdentifier)
        process.terminate()
    }

    public func dismissError() {
        errorMessage = nil
    }

    /// Clears a failed setup state after the caller has presented its error.
    public func clearFailedStart() {
        guard !isRunning, !didComplete else { return }
        status = nil
        progress = nil
        appID = nil
        generatedManifestURL = nil
        gameTitle = nil
        gameBottleURL = nil
        targetDirectory = nil
    }

    private func reset() {
        status = nil
        progress = nil
        authenticationPrompt = nil
        isRunning = false
        didComplete = false
        errorMessage = nil
        generatedManifestURL = nil
        bufferedOutput = ""
        promptScanBuffer = ""
        sawSuccess = false
        userCancelled = false
        targetDirectory = nil
        gameTitle = nil
        gameBottleURL = nil
        appID = nil
    }

    /// SteamCMD is launched through Valve's shell script, which starts the
    /// actual downloader as a child process. Stop those descendants first so
    /// Cancel cannot leave a background transfer running after the UI closes.
    private static func terminateDescendants(of processID: Int32) {
        let query = Process()
        let output = Pipe()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        query.arguments = ["-P", String(processID)]
        query.standardOutput = output
        query.standardError = output

        guard (try? query.run()) != nil else { return }
        let data = try? output.fileHandleForReading.readToEnd()
        query.waitUntilExit()
        let childIDs = String(decoding: data ?? Data(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        for childID in childIDs {
            terminateDescendants(of: childID)
            _ = kill(childID, SIGTERM)
        }
    }

    private func attachReader(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                self?.consume(data)
            }
        }
    }

    private func consume(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        bufferedOutput.append(text)
        promptScanBuffer.append(text)
        if promptScanBuffer.count > 8_192 {
            promptScanBuffer = String(promptScanBuffer.suffix(8_192))
        }

        detectAuthenticationPrompt()

        let lines = bufferedOutput.split(whereSeparator: \.isNewline)
        let hasUnterminatedTail = bufferedOutput.last.map { !$0.isNewline } ?? false
        bufferedOutput = hasUnterminatedTail ? String(lines.last ?? "") : ""
        let completeLines = hasUnterminatedTail ? lines.dropLast() : lines[...]
        for line in completeLines {
            consumeLine(String(line))
        }
        if bufferedOutput.count > 8_192 {
            bufferedOutput = String(bufferedOutput.suffix(8_192))
        }
    }

    private func detectAuthenticationPrompt() {
        guard authenticationPrompt == nil else { return }
        let lower = promptScanBuffer.lowercased()
        if lower.contains("steam guard") || lower.contains("two-factor") || lower.contains("2 factor")
            || lower.contains("two factor") || lower.contains("authenticator code")
            || lower.contains("mobile authenticator") || lower.contains("authentication code")
            || lower.contains("auth code") || lower.contains("code from your email")
            || lower.contains("email code") || lower.contains("guard code") {
            authenticationPrompt = .authenticatorCode
            status = "Enter the code requested by Steam."
            promptScanBuffer = ""
        } else if lower.contains("password for your account") || lower.contains("enter your password")
                    || lower.contains("account password")
                    || lower.range(of: #"password\s*[:>]"#, options: .regularExpression) != nil {
            authenticationPrompt = .password
            status = "Enter your Steam password."
            promptScanBuffer = ""
        }
    }

    private func consumeLine(_ rawLine: String) {
        let line = Self.removingTerminalFormatting(rawLine)
        let lower = line.lowercased()
        guard !line.isEmpty else { return }

        if let appID,
           lower.contains("success! app '\(appID)' fully installed") {
            sawSuccess = true
            status = "Verifying the completed download…"
            return
        }

        if lower.contains("progress:"), let progress = Self.parseProgress(from: line) {
            self.progress = progress
            status = "Downloading from Steam…"
            return
        }

        if lower.contains("verifying install") {
            status = "Verifying the downloaded files…"
        } else if lower.contains("downloading") {
            status = "Downloading from Steam…"
        } else if lower.contains("waiting for user info") || lower.contains("waiting for client config") {
            status = "Checking Steam account access…"
        } else if lower.contains("no subscription") || lower.contains("missing license")
                    || lower.contains("not subscribed") || lower.contains("access denied") {
            errorMessage = "Steam could not confirm access to this game for that account. Check the account and try again."
        } else if lower.contains("invalid password") || lower.contains("invalid login auth code")
                    || lower.contains("invalid two-factor") || lower.contains("invalid authenticator") {
            errorMessage = "Steam could not sign in with that response. Try again."
        } else if lower.contains("error!") || lower.contains("failed to install app") {
            errorMessage = "Steam could not finish this download. Check your connection and account access, then try again."
        }
    }

    private func finish(exitCode: Int32) {
        for pipe in outputPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
            if let remaining = try? pipe.fileHandleForReading.readToEnd(), !remaining.isEmpty {
                consume(remaining)
            }
        }
        outputPipes = []
        process = nil
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil

        if userCancelled {
            isRunning = false
            status = "Download canceled."
            return
        }
        if exitCode == 0, sawSuccess, let targetDirectory {
            generatedManifestURL = SteamCMDBootstrap.appManifestURL(appID: appID)
            status = "Checking the downloaded files…"
            guard let appID, let gameTitle, let gameBottleURL else {
                isRunning = false
                errorMessage = "Champagne could not match the completed download to its game."
                return
            }
            let manifestURL = generatedManifestURL
            Task { [weak self] in
                do {
                    let hasFiles = await Task.detached(priority: .utility) {
                        Self.hasDownloadedFiles(in: targetDirectory)
                    }.value
                    guard hasFiles else { throw SteamCMDDownloadError.missingDownloadedFiles }
                    guard let self else { return }
                    self.status = "Adding the game to your Champagne library…"
                    try await Task.detached(priority: .utility) {
                        try SteamLibrary.registerDirectDownload(
                            appID: appID,
                            title: gameTitle,
                            installURL: targetDirectory,
                            bottleURL: gameBottleURL,
                            steamCMDManifestURL: manifestURL
                        )
                    }.value
                    self.didComplete = true
                    self.isRunning = false
                    self.status = "Download complete."
                } catch {
                    guard let self else { return }
                    self.isRunning = false
                    self.status = nil
                    self.errorMessage = error.localizedDescription
                }
            }
            return
        }
        isRunning = false
        if errorMessage == nil {
            errorMessage = exitCode == 0
                ? "Steam did not confirm that the game finished downloading."
                : "Steam stopped before the download completed. Check your connection and account, then try again."
        }
        status = nil
    }

    nonisolated private static func hasDownloadedFiles(in directory: URL) -> Bool {
        let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return files?.contains { item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
            return values.isRegularFile == true
        } ?? false
    }

    private static func parseProgress(from line: String) -> SteamCMDDownloadProgress? {
        let pattern = #"progress:\s*[0-9.]+\s*\(\s*([0-9,]+)\s*/\s*([0-9,]+)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 3,
              let downloadedRange = Range(match.range(at: 1), in: line),
              let totalRange = Range(match.range(at: 2), in: line),
              let downloaded = UInt64(line[downloadedRange].replacingOccurrences(of: ",", with: "")),
              let total = UInt64(line[totalRange].replacingOccurrences(of: ",", with: "")) else { return nil }
        return SteamCMDDownloadProgress(downloadedBytes: downloaded, totalBytes: total)
    }

    private static func removingTerminalFormatting(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}

private enum SteamCMDBootstrap {
    struct Installation {
        let rootURL: URL
        let scriptURL: URL
    }

    private static let downloadURL = URL(
        string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz"
    )!

    static func prepare() async throws -> Installation {
#if arch(arm64)
        // Valve's macOS SteamCMD archive is an Intel binary. Check its package
        // receipt instead of trying to launch an Intel process here, which can
        // trigger macOS's Rosetta installation prompt over Champagne.
        let translationCheck = Process()
        let output = Pipe()
        translationCheck.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        translationCheck.arguments = ["--pkg-info", "com.apple.pkg.RosettaUpdateAuto"]
        translationCheck.standardOutput = output
        translationCheck.standardError = output
        do {
            try translationCheck.run()
            _ = try output.fileHandleForReading.readToEnd()
            translationCheck.waitUntilExit()
        } catch {
            throw SteamCMDDownloadError.x86TranslationUnavailable
        }
        guard translationCheck.terminationStatus == 0 else {
            throw SteamCMDDownloadError.x86TranslationUnavailable
        }
#endif

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = support.appending(path: Bundle.main.bundleIdentifier ?? "com.ryanng.champagne")
        let root = appFolder.appending(path: "SteamCMD")
        let macOSFolder = root.appending(path: "MacOS")
        let script = macOSFolder.appending(path: "steamcmd.sh")
        let executable = macOSFolder.appending(path: "steamcmd")

        try FileManager.default.createDirectory(
            at: macOSFolder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        if !FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) {
            let (archive, response) = try await URLSession.shared.download(from: downloadURL)
            defer { try? FileManager.default.removeItem(at: archive) }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url?.scheme?.lowercased() == "https",
                  http.url?.host?.lowercased() == downloadURL.host?.lowercased() else {
                throw SteamCMDDownloadError.downloadServiceUnavailable
            }
            let handle = try FileHandle(forReadingFrom: archive)
            let signature = try handle.read(upToCount: 2)
            try handle.close()
            guard signature == Data([0x1f, 0x8b]) else {
                throw SteamCMDDownloadError.invalidDownloadService
            }
            try await Task.detached(priority: .utility) {
                try Tar.untar(tarBall: archive, toURL: macOSFolder)
            }.value
        }

        guard FileManager.default.fileExists(atPath: script.path(percentEncoded: false)) else {
            throw SteamCMDDownloadError.invalidDownloadService
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            throw SteamCMDDownloadError.invalidDownloadService
        }
        return Installation(rootURL: root, scriptURL: script)
    }

    static func appManifestURL(appID: Int?) -> URL? {
        guard let appID else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = support.appending(path: Bundle.main.bundleIdentifier ?? "com.ryanng.champagne")
        let root = appFolder.appending(path: "SteamCMD")
        let filename = "appmanifest_\(appID).acf"
        let candidates = [
            root.appending(path: "steamapps").appending(path: filename),
            root.appending(path: "MacOS/steamapps").appending(path: filename),
            root.appending(path: "AccountHome/Library/Application Support/Steam/steamapps").appending(path: filename)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}

private enum SteamCMDDownloadError: LocalizedError {
    case invalidAppID
    case invalidAccountName
    case invalidInstallLocation
    case missingDownloadedFiles
    case noAuthenticationPrompt
    case invalidAuthenticationResponse
    case downloadServiceUnavailable
    case invalidDownloadService
    case x86TranslationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAppID:
            "This Steam game has an invalid App ID."
        case .invalidAccountName:
            "Enter your Steam account name to continue."
        case .invalidInstallLocation:
            "Champagne could not prepare a game download folder."
        case .missingDownloadedFiles:
            "Steam finished, but Champagne could not find the downloaded game files."
        case .noAuthenticationPrompt:
            "Steam is not currently requesting a sign-in response."
        case .invalidAuthenticationResponse:
            "Enter the response requested by Steam."
        case .downloadServiceUnavailable:
            "SteamCMD could not be downloaded securely. Check your connection and try again."
        case .invalidDownloadService:
            "Champagne could not prepare its Steam download service. Try again later."
        case .x86TranslationUnavailable:
            "Steam's download service requires Rosetta on this Mac. Install Rosetta, then try again."
        }
    }
}
