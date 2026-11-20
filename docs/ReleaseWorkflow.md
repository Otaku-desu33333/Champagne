# Release Workflow

Champagne has two release artifact types:

- App: Champagne-X.Y.Z.dmg, attached to an app-vX.Y.Z GitHub Release.
- Wine runtime: Libraries.tar.gz, attached to a vX.Y.Z GitHub Release.

The app's runtime manifest is dist/pages/WhiskyWineVersion.plist, deployed with GitHub Pages by .github/workflows/Documentation.yml. The Sparkle feed configured in the app is the root appcast.xml.

## App release

1. Update MARKETING_VERSION and CURRENT_PROJECT_VERSION in Whisky.xcodeproj/project.pbxproj. The build number must increase monotonically for Sparkle.
2. Move release notes from [Unreleased] to a dated version section in CHANGELOG.md.
3. On the Mac release machine, configure the Developer ID signing identity and the notarytool keychain profile expected by scripts/release.sh.
4. Run scripts/release.sh X.Y.Z. The script archives the Whisky Xcode scheme, exports and verifies Champagne.app, creates Champagne-X.Y.Z.dmg, notarizes it, and staples the ticket. The artifact is written under build/release/.
5. If Sparkle updates are enabled, sign the exact DMG with Sparkle's sign_update tool. Add its signature and byte length to both appcast.xml and dist/pages/appcast.xml, and use this release URL:

   https://github.com/Otaku-desu33333/Champagne/releases/download/app-vX.Y.Z/Champagne-X.Y.Z.dmg

6. Commit the release metadata, push the branch, then create and publish the app-vX.Y.Z tag and GitHub Release.

Sparkle distribution also requires the matching public key in the app and its private key on the signing machine. Do not regenerate that key for an established update channel.

## Wine runtime release

scripts/assemble-runtime.sh assembles a runtime from pinned upstream binaries. It verifies the base runtime and DXMT archive, then prints the resulting SHA-256 digest and publishing steps.

Before publishing a new runtime:

1. Review the pinned component versions and license terms in docs/DEPENDENCIES.md. Confirm redistribution rights for every bundled component.
2. Run the assembly script with the intended version and complete its local compatibility checks.
3. Publish the archive as Libraries.tar.gz on a bare vX.Y.Z GitHub Release in this repository.
4. Copy the SHA-256 digest of that exact release asset into dist/pages/WhiskyWineVersion.plist; verify the version, digest, and runtime metadata match the uploaded archive.
5. Update docs/DEPENDENCIES.md and .github/workflows/RuntimeTrack.yml, then commit and push. The Pages workflow deploys the updated manifest.

The runtime catalog also lists Wine Libraries releases from the configured community repository. Catalog downloads require a GitHub-published SHA-256 digest and are installed as named runtimes without replacing Libraries/.

## External setup

GitHub Pages, release publishing, Sparkle signing, Apple Developer signing, and notarization each require account or repository configuration. The source config points to this repository, but these credentials and service settings must be completed by the maintainer before production distribution.
