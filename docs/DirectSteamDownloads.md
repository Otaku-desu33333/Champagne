# Direct Steam downloads: development plan

Champagne's current Discover flow starts the Windows Steam installer and hands
game installation to Steam. That is an existing prototype, not the target flow.
The target is to sign in to Steam and start, monitor, and manage downloads in
Champagne. Steam must decide whether the account has access to the content.

## Investigation

[DepotDownloader](https://github.com/SteamRE/DepotDownloader) is a possible
backend. It can authenticate with Steam, select Windows content on macOS, and
download Steam depots. It is a third-party command-line application, not an
official Valve integration. Its license, release packaging, authentication and
output interfaces must be evaluated before distribution. Do not pass a
password as a command-line argument or write credentials to logs.

An isolated investigation on Apple Silicon connected anonymously to Steam and
retrieved Windows manifests for the public Team Fortress 2 dedicated server
(app 232250). A subsequent filtered download retrieved one 1,740-byte file;
its SHA-1 matched the value in the Steam manifest. This checks public server
content only; it does not demonstrate account sign-in, entitlement checks, a
complete game install, or launching.

## Milestones

1. Prove account sign-in, Steam Guard and access-denied behavior without
   exposing credentials, then establish a supported way to integrate the
   downloader and manage its session securely.
2. Download a selected owned Windows game into an isolated managed location;
   implement reliable progress, cancellation, retry, and restart recovery.
3. Integrate installed games with the library and verify launching, including
   required Steam client, DRM and first-run dependencies. A successful file
   download alone must not be presented as proof that a game is playable.
4. Add and verify the curated free-game publisher flows separately. Preserve
   existing Whisky and Champagne data throughout testing.

The Steam-window prototype remains in the tree until a replacement is ready;
it must not be described as the completed direct-download experience.
