# Steam downloads from Champagne

Champagne owns discovery and the install experience. The official Steam client
remains responsible for sign-in, entitlement checks, and game content. On the
first install, Champagne prepares Steam inside its managed game environment,
sends the selected App ID to Steam, and reads Steam's install manifest for
progress and completion. This keeps one Steam account session for both
downloading and launching.

## Direct downloader investigation

[DepotDownloader](https://github.com/SteamRE/DepotDownloader) can authenticate
with Steam, select Windows content on macOS, and download depots. It is a
third-party command-line application, not an official Valve integration. It
creates its own Steam session, separate from the Steam client Champagne needs
for many games, and its default implementation persists refresh-token data in
its local settings store. That creates separate sign-in and session handling,
and the isolated file test did not establish a complete, playable install. It
is not the selected production path.

The isolated test connected anonymously to Steam and retrieved Windows
manifests for the public Team Fortress 2 dedicated server (app 232250). A
filtered download retrieved one 1,740-byte file whose SHA-1 matched the Steam
manifest. This proves the downloader can fetch public content; it does not
prove account sign-in, entitlement checks, or game installation.

## Remaining verification

1. Verify silent Steam client setup, sign-in, ownership checks, and install
   handoff on the user's Mac.
2. Complete and verify progress, retry, and restart recovery for selected games.
3. Integrate installed games with the library and verify launching, including
   Steam client, DRM, and first-run dependencies.
4. Add and verify curated free-game publisher flows separately. Preserve
   existing Whisky and Champagne data throughout testing.
