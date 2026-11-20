# Distribution

Champagne's source repository is Otaku-desu33333/Champagne.

- App releases and Wine runtime archives are published through this repository's GitHub Releases.
- scripts/release.sh builds the Champagne-X.Y.Z.dmg app artifact.
- .github/workflows/Documentation.yml deploys static files from dist/pages/, including the Wine runtime version manifest.
- The appcast feed is read from this repository's root appcast.xml.
- No Homebrew tap or automatic Homebrew publishing workflow is configured.

Publishing a signed and notarized app still depends on the maintainer's Apple Developer credentials and repository release configuration. See the [Release Workflow](ReleaseWorkflow.md) for local steps and the external setup that remains.
