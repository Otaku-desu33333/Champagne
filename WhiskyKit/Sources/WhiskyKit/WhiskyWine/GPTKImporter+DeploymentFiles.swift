//
//  GPTKImporter+DeploymentFiles.swift
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

/// Performs file operations for deploying the stored payload into Wine runtimes.
extension GPTKImporter {
    static func deployForwarders(from storeLib: URL, into peDirectory: URL, originals: URL) throws {
        let fileManager = FileManager.default
        for name in forwarderDLLNames {
            let target = peDirectory.appending(path: name)
            let backup = originals.appending(path: name)
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
    }

    static func deployUnixBridges(into unixDirectory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: unixDirectory, withIntermediateDirectories: true)
        for name in unixLibraryNames {
            let link = unixDirectory.appending(path: name)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(
                atPath: link.path(percentEncoded: false),
                withDestinationPath: unixLinkDestination
            )
        }
    }

    static func deployExternalPayload(from storeLib: URL, into wineLib: URL) throws {
        let fileManager = FileManager.default
        let external = wineLib.appending(path: "external")
        let values = try? external.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true || (values != nil && values?.isDirectory != true) {
            throw GPTKImportError.runtimePayloadConflict(external.path(percentEncoded: false))
        }
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)

        let storeExternal = storeLib.appending(path: "external")
        let items = try fileManager.contentsOfDirectory(at: storeExternal, includingPropertiesForKeys: nil)
        for source in items {
            let destination = external.appending(path: source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                guard fileSystemItemsMatch(destination, source) else {
                    throw GPTKImportError.runtimePayloadConflict(destination.path(percentEncoded: false))
                }
                continue
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    static func installRuntimeBridges(into folder: URL, usingStore store: URL) throws {
        // Apple's payload must be in place before bridges that link against it.
        try installMetalFXBridge(intoLibraryFolder: folder, usingStore: store)
        // Deploy interposers only for payload builds they were validated against.
        for interposer in interposers {
            try install(interposer, intoLibraryFolder: folder)
        }
        try installNVAPIBridge(intoLibraryFolder: folder, usingStore: store)
    }
}
