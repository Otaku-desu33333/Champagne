<div align="center">

# Champagne 🍾

*Run Windows games and applications on macOS with Wine.*

</div>

Champagne is a native SwiftUI Wine manager derived from the archived [Whisky project](https://github.com/whisky-app/whisky). It lets you create bottles, install Windows applications, and choose Wine runtimes and graphics backends per bottle. Champagne is an independent project and is not affiliated with the original Whisky project or getwhisky.app.

## Features

- Manage separate Wine bottles for Windows applications and games.
- Choose among installed Wine runtimes for each bottle, or import a runtime archive.
- Browse runtime releases from Champagne and the community runtime catalog. Catalog archives are accepted only from the configured GitHub repositories when GitHub provides a SHA-256 digest.
- Select graphics options such as DXVK, DXMT, or D3DMetal when the selected runtime supports them.
- Use built-in launcher compatibility, Winetricks, diagnostics, and game configuration tools.

## Requirements

- Apple Silicon Mac (arm64)
- macOS 15 or later

## Get Champagne

Published builds, when available, are listed on [GitHub Releases](https://github.com/Otaku-desu33333/Champagne/releases). The release and runtime download URLs are configured for this repository; release signing, notarization, and update-feed credentials must be configured before distributing production builds.

To build from source, open Whisky.xcodeproj in Xcode and run the Whisky scheme. The Xcode project and Swift package retain their historical Whisky names.

## Wine runtimes

Existing bottles continue to use the default Libraries/ runtime. Additional catalog or imported runtimes are stored side by side under the Champagne application-support folder and can be selected per bottle. Switching a bottle's runtime is blocked while that bottle has running Wine processes.

Runtime catalog archives are verified against GitHub's published SHA-256 before extraction. They are installed into a staging directory, validated, and then moved into their own runtime folder; they do not replace the default runtime.

Some runtimes support Apple's Game Porting Toolkit payload and others do not. Champagne checks the runtime metadata before offering GPTK deployment.

## Migrate from a Whisky installation

Use **File → Import Bottles from Whisky** to find bottles from the original and community Whisky apps. Selected bottle folders are referenced in place, so Champagne and Whisky use the same bottle files. Wine runtimes and imported GPTK data are stored separately and are not migrated with bottles; install or import them in Champagne as needed.

## Support and security

- [Support and bug reports](docs/SUPPORT.md)
- [Security policy](SECURITY.md)
- [Release workflow](docs/ReleaseWorkflow.md)

## License

Champagne is distributed under the GNU General Public License, version 3. See [LICENSE](LICENSE) for the full terms. The project retains attribution to upstream Whisky contributors and third-party runtime components.
