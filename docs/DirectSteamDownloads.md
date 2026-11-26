# Direct Steam downloads from Champagne

Champagne owns the discovery and install flow. Selecting a Steam game prepares
the managed game environment, installs the Windows Steam client for launch
compatibility, then starts a Windows depot download through Valve's macOS
SteamCMD. Champagne presents the account, password, and verification prompts,
shows download progress, and registers the completed files in its game library.
The password and verification response go to SteamCMD through standard input;
neither is placed in the process arguments or Champagne's logs. SteamCMD's
local account data is directed to a private Champagne support folder with
owner-only permissions.

## Known launch limitation

SteamCMD checks the account and downloads the files, but that login is separate
from the Windows Steam client inside the managed environment. Games that use
Steam DRM or Steamworks may ask the user to sign in to that client the first
time they launch. Champagne does not claim that the SteamCMD session also
authenticates the game client.

Champagne copies SteamCMD's app manifest into the managed Steam library when it
is available. If SteamCMD changes where it writes that file, Champagne writes a
minimal local manifest so its library can list the downloaded game. The
Windows Steam client may then validate or update the files on first launch; an
end-to-end game install must confirm it does not redownload the full game.

## Support boundary

Valve documents a macOS SteamCMD build in its Steamworks upload guide and
describes SteamCMD downloads in its standalone game-server support guide. The
guide does not promise that SteamCMD is a supported replacement for the Steam
client's regular game-download UI. Champagne uses its documented command-line
download behavior for Windows depots, but we still need to validate account
eligibility, manifest handoff, resume behavior, and launch against a small
owned game on the target Mac.

- [Valve Steamworks: Uploading to Steam](https://partner.steamgames.com/doc/sdk/uploading)
- [Steam Support: Download, install, and update a standalone server](https://help.steampowered.com/en/faqs/view/5E9C-65C2-C968-98DC)

## Separate investigation

[DepotDownloader](https://github.com/SteamRE/DepotDownloader) can select
Windows depots and retrieve public content. It is a third-party SteamKit2
client, not a Valve integration. Its separate session handling and
GPL-2.0-only license make it a poor fit for bundling in this GPL-3.0-or-later
app. An earlier isolated test retrieved a small public Team Fortress 2 server
file and verified its hash; that did not establish a complete game install.
