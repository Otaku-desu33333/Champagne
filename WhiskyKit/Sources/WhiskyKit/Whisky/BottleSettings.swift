Warning: truncated output (original token count: 13270)
Total output lines: 1233

// swiftlint:disable file_length
//
//  BottleSettings.swift
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
import SemanticVersion

/// Represents a pinned program entry in a bottle's quick-access list.
///
/// Pinned programs appear in a prominent location in the UI for fast access.
/// The pin tracks whether the program is on a removable volume so it can
/// handle disconnected drives gracefully.
public struct PinnedProgram: Codable, Hashable, Equatable {
    /// The display name for the pinned program.
    public var name: String
    /// The URL to the program's executable file.
    public var url: URL?
    /// Whether the program is stored on a removable volume.
    ///
    /// When `true`, the pin remains valid even if the volume is disconnected.
    public var removable: Bool

    /// Creates a new pinned program entry.
    ///
    /// - Parameters:
    ///   - name: The display name for the pin.
    ///   - url: The URL to the program's executable.
    public init(name: String, url: URL) {
        self.name = name
        self.url = url
        do {
            let volume = try url.resourceValues(forKeys: [.volumeURLKey]).volume
            self.removable = try !(volume?.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal ?? false)
        } catch {
            self.removable = false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.url = try container.decodeIfPresent(URL.self, forKey: .url)
        self.removable = try container.decodeIfPresent(Bool.self, forKey: .removable) ?? false
    }
}

/// Basic information about a bottle including its name and pinned programs.
///
/// This struct contains the user-visible metadata for a bottle that isn't
/// related to Wine configuration.
public struct BottleInfo: Codable, Equatable {
    /// The display name of the bottle.
    var name: String = "Bottle"
    /// The list of pinned programs for quick access.
    var pins: [PinnedProgram] = []
    /// URLs of programs that should be hidden from the program list.
    var blocklist: [URL] = []

    /// Creates a new BottleInfo with default values.
    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Bottle"
        self.pins = try container.decodeIfPresent([PinnedProgram].self, forKey: .pins) ?? []
        self.blocklist = try container.decodeIfPresent([URL].self, forKey: .blocklist) ?? []
    }
}

// swiftlint:disable type_body_length
/// The complete configuration settings for a Wine bottle.
///
/// `BottleSettings` is the main configuration type for a bottle, containing all
/// settings related to Wine, Metal graphics, DXVK, and performance. It's automatically
/// serialized to a plist file in the bottle directory.
///
/// ## Overview
///
/// Settings are organized into logical groups:
/// - **Info**: Name, pins, and blocklist
/// - **Runtime**: The selected Wine runtime identifier
/// - **Wine Config**: Windows version, AVX, enhanced sync
/// - **Metal Config**: Metal HUD, DXR, validation
/// - **DXVK Config**: DXVK enable, async, HUD
/// - **Performance Config**: Shader cache, App Nap, VC++ runtime tracking
///
/// ## Example
///
/// ```swift
/// var settings = BottleSettings()
/// settings.name = "Gaming"
/// settings.windowsVersion = .win10
/// settings.dxvk = true
/// ```
///
/// ## Topics
///
/// ### Basic Information
/// - ``name``
/// - ``pins``
/// - ``blocklist``
///
/// ### Wine Configuration
/// - ``windowsVersion``
/// - ``wineVersion``
/// - ``avxEnabled``
/// - ``enhancedSync``
///
/// ### Graphics Settings
/// - ``metalHud``
/// - ``metalTrace``
/// - ``metalValidation``
/// - ``dxrEnabled``
/// - ``sequoiaCompatMode``
/// - ``metal4Enabled``
///
/// ### DXVK Settings
/// - ``dxvk``
/// - ``dxvkAsync``
/// - ``dxvkHud``
///
/// ### Performance
/// - ``shaderCacheEnabled``
/// - ``vcRedistInstalled``
public struct BottleSettings: Codable, Equatable {
    /// The current file format version for settings serialization.
    static let defaultFileVersion = SemanticVersion(1, 0, 0)
    /// The version of the settings file format.
    var fileVersion: SemanticVersion = Self.defaultFileVersion
    /// Basic bottle information (name, pins).
    private var info: BottleInfo
    /// Stable identifier for the Wine runtime this bottle uses. `nil` keeps
    /// existing bottles on the legacy default runtime. Set it through
    /// ``WineRuntimeStore/select(_:for:)`` so only installed runtimes are saved.
    public internal(set) var wineRuntimeIdentifier: String?
    /// Wine-specific configuration.
    private var wineConfig: BottleWineConfig
    /// Metal graphics settings.
    private var metalConfig: BottleMetalConfig
    /// DXVK translation layer settings.
    private var dxvkConfig: BottleDXVKConfig
    /// Performance optimization settings.
    private var performanceConfig: BottlePerformanceConfig
    /// Game launcher compatibility settings.
    private var launcherConfig: BottleLauncherConfig
    /// Controller and input device settings.
    private var inputConfig: BottleInputConfig
    /// Cleanup and clipboard behavior settings.
    private var cleanupConfig: BottleCleanupConfig
    /// Graphics backend selection.
    private var graphicsConfig: BottleGraphicsConfig
    /// Display resolution and virtual desktop settings.
    private var displayConfig: BottleDisplayConfig
    /// Audio driver, latency, and device settings.
    private var audioConfig: BottleAudioConfig
    /// Discord presence and rich presence bridging.
    private var discordConfig: BottleDiscordConfig
    /// User-defined DLL overrides at the bottle level.
    private var customDLLOverrides: [DLLOverrideEntry] = []
    /// Environment variables applied game configurations set for games that
    /// were not in the bottle yet, scoped to their executables. See
    /// ``GameConfigEnvironment``.
    public var gameConfigEnvironments: [GameConfigEnvironment] = []

    /// Creates a new BottleSettings instance with default values.
    public init() {
        self.info = BottleInfo()
        self.wineRuntimeIdentifier = nil
        self.wineConfig = BottleWineConfig()
        self.metalConfig = BottleMetalConfig()
        self.dxvkConfig = BottleDXVKConfig()
        self.performanceConfig = BottlePerformanceConfig()
        self.launcherConfig = BottleLauncherConfig()
        self.inputConfig = BottleInputConfig()
        self.cleanupConfig = BottleCleanupConfig()
        self.graphicsConfig = BottleGraphicsConfig()
        self.displayConfig = BottleDisplayConfig()
        self.audioConfig = BottleAudioConfig()
        self.discordConfig = BottleDiscordConfig()
        self.customDLLOverrides = []
    }

    // swiftlint:disable:next function_body_length
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileVersion = try container.decodeIfPresent(SemanticVersion.self, forKey: .fileVersion) ?? Self
            .defaultFileVersion
        self.info = try container.decodeIfPresent(BottleInfo.self, forKey: .info) ?? BottleInfo()
        self.wineRuntimeIdentifier = try container.decodeIfPresent(String.self, forKey: .wineRuntimeIdentifier)
        self.wineConfig = try container
            .decodeIfPresent(BottleWineConfig.self, forKey: .wineConfig) ?? BottleWineConfig()
        self.metalConfig = try container
            .decodeIfPresent(BottleMetalConfig.self, forKey: .metalConfig) ?? BottleMetalConfig()
        self.dxvkConfig = try container
            .decodeIfPresent(BottleDXVKConfig.self, forKey: .dxvkConfig) ?? BottleDXVKConfig()
        self.performanceConfig = try container.decodeIfPresent(
            BottlePerformanceConfig.self,
            forKey: .performanceConfig
        ) ?? BottlePerformanceConfig()
        self.launcherConfig = try container.decodeIfPresent(
            BottleLauncherConfig.self,
            forKey: .launcherConfig
        ) ?? BottleLauncherConfig()
        self.inputConfig = try container.decodeIfPresent(
            BottleInputConfig.self,
            forKey: .inputConfig
        ) ?? BottleInputConfig()
        self.cleanupConfig = try container.decodeIfPresent(
            BottleCleanupConfig.self,
            forKey: .cleanupConfig
        ) ?? BottleCleanupConfig()
        let hasGraphicsConfig = container.contains(.graphicsConfig)
        self.graphicsConfig = try container.decodeIfPresent(
            BottleGraphicsConfig.self,
            forKey: .graphicsConfig
        ) ?? BottleGraphicsConfig()
        // Migration: preserve DXVK choice from old bottles that lack graphicsConfig
        if !hasGraphicsConfig, self.dxvkConfig.dxvk {
            self.graphicsConfig.backend = .dxvk
        }
        self.displayConfig = try container.decodeIfPresent(
            BottleDisplayConfig.self,
            forKey: .displayConfig
        ) ?? BottleDisplayConfig()
        self.audioConfig = try container.decodeIfPresent(
            BottleAudioConfig.self,
            forKey: .audioConfig
        ) ?? BottleAudioConfig()
        self.discordConfig = try container.decodeIfPresent(
            BottleDiscordConfig.self,
            forKey: .discordConfig
        ) ?? BottleDiscordConfig()
        self.customDLLOverrides = try container.decodeIfPresent(
            [DLLOverrideEntry].self,
            forKey: .customDLLOverrides
        ) ?? []
        self.gameConfigEnvironments = try container.decodeIfPresent(
            [GameConfigEnvironment].self,
            forKey: .gameConfigEnvironments
        ) ?? []
    }

    /// The display name of this bottle.
    public var name: String {
        get { info.name }
        set { info.name = newValue }
    }

    /// The Wine version used when this bottle was created.
    ///
    /// This is automatically updated when Wine is upgraded.
    public var wineVersion: SemanticVersion {
        get { wineConfig.wineVersion }
        set { wineConfig.wineVersion = newValue }
    }

    /// The Windows version that Wine emulates for this bottle.
    ///
    /// Different Windows versions may provide better compatibility
    /// for different applications. Windows 10 is recommended for most games.
    public var windowsVersion: WinVersion {
        get { wineConfig.windowsVersion }
        set { wineConfig.windowsVersion = newValue }
    }

    /// Whether AVX instruction set support is advertised to programs.
    ///
    /// Enable this via Rosetta 2 for programs that require AVX instructions.
    /// Only applicable on Apple Silicon Macs.
    public var avxEnabled: Bool {
        get { wineConfig.avxEnabled }
        set { wineConfig.avxEnabled = newValue }
    }

    /// The list of pinned programs for quick access.
    public var pins: [PinnedProgram] {
        get { info.pins }
        set { info.pins = newValue }
    }

    /// URLs of programs that should be hidden from the program list.
    ///
    /// Use this to hide unwanted executables like installers or utilities.
    public var blocklist: [URL] {
        get …7270 tokens truncated…builder.set("WINEESYNC", "1", layer: .bottleManaged)
        case .msync:
            builder.set("WINEMSYNC", "1", layer: .bottleManaged)
            // D3DM detects ESYNC and changes behaviour accordingly
            // so we have to lie to it so that it doesn't break
            // under MSYNC. Values hardcoded in lid3dshared.dylib
            builder.set("WINEESYNC", "1", layer: .bottleManaged)
        }

        if metalHud {
            builder.set("MTL_HUD_ENABLED", "1", layer: .bottleManaged)
        }

        if metalTrace {
            builder.set("METAL_CAPTURE_ENABLED", "1", layer: .bottleManaged)
        }

        if avxEnabled {
            builder.set("ROSETTA_ADVERTISE_AVX", "1", layer: .bottleManaged)
        }

        if dxrEnabled {
            builder.set("D3DM_SUPPORT_DXR", "1", layer: .bottleManaged)
        }

        // Metal validation - useful for debugging but can impact performance
        if metalValidation {
            builder.set("MTL_DEBUG_LAYER", "1", layer: .bottleManaged)
        }

        // The old sequoiaCompatMode block is gone: of the three values it set,
        // MTL_DEBUG_LAYER and WINEFSYNC are platform-layer fixes on every
        // supported macOS and D3DM_VALIDATION is read by no runtime, so the
        // toggle's off position changed nothing and its on position only hid
        // the provenance.

        // Shader cache control. DXVK_STATE_CACHE is the variable DXVK actually
        // reads; the previous pair (a compile-thread throttle and an NVIDIA GL
        // driver variable) changed nothing on this platform.
        if !shaderCacheEnabled {
            builder.set("DXVK_STATE_CACHE", "0", layer: .bottleManaged)
        }

        return managedDLLOverrides
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    /// Populates the ``EnvironmentLayer/launcherManaged`` layer with launcher compatibility fixes.
    ///
    /// This method implements the dual-mode launcher compatibility system from frankea/Whisky#41:
    /// - Merges launcher-specific environment overrides
    /// - Applies the bottle's explicit Locale Override over any preset locale
    /// - Configures GPU spoofing for launcher checks
    /// - Sets network timeouts for download reliability
    ///
    /// - Parameters:
    ///   - builder: The environment builder to populate.
    ///   - builtinD3D12IsD3DMetal: Whether the runtime's builtin `d3d12` is
    ///     D3DMetal's, passed on to the DXVK preset a launcher can require.
    ///     Defaults to whether the GPTK payload is deployed.
    /// - Returns: Launcher-required DLL override entries with their sources.
    public func populateLauncherManagedLayer(
        builder: inout EnvironmentBuilder,
        builtinD3D12IsD3DMetal: Bool? = nil
    ) -> [(entry: DLLOverrideEntry, source: DLLOverrideSource)] {
        var launcherDLLOverrides: [(entry: DLLOverrideEntry, source: DLLOverrideSource)] = []
        let builtinD3D12IsD3DMetal = builtinD3D12IsD3DMetal ?? GPTKImporter.isDeployed(for: self)

        guard launcherCompatibilityMode else { return launcherDLLOverrides }

        // Apply launcher-specific environment overrides if launcher detected
        if let launcher = detectedLauncher {
            for detail in launcher.fixDetails() {
                builder.set(detail.key, detail.value, layer: .launcherManaged, reason: detail.reason)
            }

            // Auto-enable DXVK DLL overrides if launcher requires it
            if autoEnableDXVK, launcher.requiresDXVK {
                for entry in DLLOverrideResolver.dxvkPreset(builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal) {
                    launcherDLLOverrides.append((entry: entry, source: .launcher(launcher.displayName)))
                }
            }
        }

        // An explicit Locale Override replaces the preset's locale. Some presets
        // set LC_ALL to en_US for the launchers' web views, but every game a
        // launcher starts inherits it, and a game that takes its region or
        // language from the Windows locale needs the user's choice (#330).
        // Auto keeps the preset's value, or the Mac's when there is none.
        // The rawValue check keeps LC_ALL/LANG from ever being set to "".
        if launcherLocale != .auto, !launcherLocale.rawValue.isEmpty {
            // The reason replaces the preset's, which would otherwise stay
            // attached to the overridden value in provenance.
            let reason = "Set by the bottle's Locale Override"
            builder.set("LC_ALL", launcherLocale.rawValue, layer: .launcherManaged, reason: reason)
            builder.set("LANG", launcherLocale.rawValue, layer: .launcherManaged, reason: reason)
            // Force C locale for date/time parsing to avoid ICU issues
            builder.set("LC_TIME", "C", layer: .launcherManaged)
            builder.set("LC_NUMERIC", "C", layer: .launcherManaged)
        }

        // Apply GPU spoofing if enabled
        if gpuSpoofing {
            let gpuEnv = spoofEnvironment()
            let launcherEnv = detectedLauncher?.environmentOverrides() ?? [:]
            // Don't override values already set by launcher preset (original behavior:
            // merge with "current.isEmpty ? new : current")
            for (key, value) in gpuEnv {
                let existing = launcherEnv[key]
                if existing == nil || (existing?.isEmpty ?? true) {
                    builder.set(key, value, layer: .launcherManaged)
                }
            }
        }

        // Network timeout configuration
        // Applied if user customized timeout (including launcher-set values)
        // Launcher-specific timeouts are set via bottle.settings.networkTimeout by
        // LauncherFixes.apply(), giving users control via UI slider
        if networkTimeout != 60_000 { // If not default (60s)
            builder.set("WINHTTP_CONNECT_TIMEOUT", String(networkTimeout), layer: .launcherManaged)
            builder.set("WINHTTP_RECEIVE_TIMEOUT", String(networkTimeout * 2), layer: .launcherManaged)
        }

        // The connection-pooling and SSL variables that used to be set here
        // (WINE_MAX_CONNECTIONS_PER_SERVER and friends) exist in no Wine or
        // WineCX source; nothing ever read them.

        return launcherDLLOverrides
    }

    /// The GPU spoof environment with the ray tracing key resolved against
    /// the bottle's own settings.
    ///
    /// Ray tracing has its own toggle, ``dxrEnabled``, whose bottle layer sets `D3DM_SUPPORT_DXR` when it is on.
    /// Unlike the rest of the spoof, that one is read by D3DMetal. It
    /// only matters to games, since launcher UIs render on DXVK, and every game
    /// a launcher starts inherits the launcher's environment. So the spoof
    /// turned DXR on for every game in a bottle that Play had configured for
    /// Steam, over the toggle (off by default, and not offered at all on Macs
    /// without hardware ray tracing) and over the troubleshooter's "Disable Ray
    /// Tracing" fix.
    private func spoofEnvironment() -> [String: String] {
        var gpuEnv = GPUDetection.spoofWithVendor(gpuVendor)
        gpuEnv.removeValue(forKey: "D3DM_SUPPORT_DXR")
        return gpuEnv
    }

    /// Populates the ``EnvironmentLayer/bottleManaged`` layer with controller/input compatibility fixes.
    ///
    /// Sets SDL environment variables to improve gamepad detection and functionality.
    /// See: https://wiki.libsdl.org/SDL2/CategoryHints (applies to both SDL2 and SDL3)
    ///
    /// - Parameter builder: The environment builder to populate.
    public func populateInputCompatibilityLayer(builder: inout EnvironmentBuilder) {
        guard controllerCompatibilityMode else { return }

        // Disable HIDAPI - forces SDL to use alternative input backend
        // May improve detection for controllers that don't work with HIDAPI
        if disableHIDAPI {
            builder.set("SDL_JOYSTICK_HIDAPI", "0", layer: .bottleManaged)
        }

        // Allow joystick events when app is in background
        // Useful for controller input when Wine window loses focus
        if allowBackgroundEvents {
            builder.set("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1", layer: .bottleManaged)
        }

        // Disable SDL to XInput mapping conversion
        // PlayStation/Switch controllers may show correct button mappings without this
        // Both disableControllerMapping (legacy) and useButtonLabels (controller panel) control this hint.
        if disableControllerMapping || useButtonLabels {
            builder.set("SDL_GAMECONTROLLER_USE_BUTTON_LABELS", "1", layer: .bottleManaged)
        } else {
            builder.set("SDL_GAMECONTROLLER_USE_BUTTON_LABELS", "0", layer: .bottleManaged)
        }
    }

    /// Populates the audio layer of the environment builder.
    ///
    /// Audio configuration in Wine is **registry-backed**, not environment-variable-backed.
    /// The audio driver (`HKCU\Software\Wine\Drivers\Audio`) and DirectSound buffer size
    /// (`HKCU\Software\Wine\DirectSound\HelBuflen`) are applied via ``WineAudioRegistry``
    /// methods, not through this layer populator.
    ///
    /// This method exists as the EnvironmentBuilder integration point for audio settings,
    /// following the pattern of ``populateInputCompatibilityLayer(builder:)``. It is reserved
    /// for future audio-related environment variables (e.g., `WINEDEBUG` channels for audio
    /// debugging).
    ///
    /// - Parameter builder: The environment builder to populate.
    public func populateAudioLayer(builder: inout EnvironmentBuilder) {
        // Audio settings are applied via Wine registry (WineAudioRegistry), not env vars.
        // This placeholder ensures the EnvironmentBuilder cascade has an audio integration
        // point for future audio-related environment variables.
    }

    // MARK: - Deprecated Environment Variable API

    /// Populates a Wine environment dictionary based on these settings.
    ///
    /// - Parameter wineEnv: The environment dictionary to populate.
    ///   Existing values may be modified or removed based on settings.
    @available(*, deprecated, message: "Use EnvironmentBuilder layer populators instead")
    public func environmentVariables(wineEnv: inout [String: String]) {
        var builder = EnvironmentBuilder()

        // Call layer populators
        let builtinD3D12IsD3DMetal = GPTKImporter.isDeployed(for: self)
        let managedOverrides = populateBottleManagedLayer(
            builder: &builder,
            resolvedBackend: GraphicsBackendResolver.resolve(for: self),
            builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal
        )
        let launcherOverrides = populateLauncherManagedLayer(
            builder: &builder,
            builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal
        )
        populateInputCompatibilityLayer(builder: &builder)

        // Resolve and merge
        let (resolved, _) = builder.resolve()

        // Handle explicit key removals that the builder encoded as nil entries.
        // Since resolve() omits removed keys, we must also remove them from the caller's dict.
        if enhancedSync == .none, MacOSVersion.current < .sequoia15_4 {
            wineEnv.removeValue(forKey: "WINEESYNC")
            wineEnv.removeValue(forKey: "WINEMSYNC")
        }

        // Merge resolved values into caller's dict (new values overwrite existing)
        wineEnv.merge(resolved) { _, new in new }

        // Compose WINEDLLOVERRIDES via DLLOverrideResolver
        let resolver = DLLOverrideResolver(
            managed: managedOverrides + launcherOverrides,
            bottleCustom: dllOverrides,
            programCustom: []
        )
        let (overrideString, _) = resolver.resolve()
        if !overrideString.isEmpty {
            wineEnv["WINEDLLOVERRIDES"] = overrideString
        }
    }
}

// swiftlint:enable type_body_length
