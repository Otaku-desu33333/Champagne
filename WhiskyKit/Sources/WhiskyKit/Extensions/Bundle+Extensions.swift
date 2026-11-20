//
//  Bundle+Extensions.swift
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

public extension Bundle {
    /// Champagne's stable storage and logging namespace. The CLI and thumbnail
    /// extension have their own bundle IDs, but they must address the same app data.
    static var champagneBundleIdentifier: String {
        "com.ryanng.champagne"
    }

    /// Compatibility alias for clients that still use WhiskyKit's former name.
    static var whiskyBundleIdentifier: String {
        champagneBundleIdentifier
    }
}
