# Steam install handoff check

The code and app build are ready for an end-to-end check on the Mac that will
run Champagne. This check uses the user's Steam account only inside Steam; do
not share passwords or Steam Guard codes in diagnostics.

1. Build the current `codex/steam-first-library` branch and open Discover.
2. Choose a small Windows game already owned by the signed-in account and
   select **Install in Champagne**.
3. Confirm the game environment is created automatically and the Steam
   installer wizard stays hidden. Steam may open for sign-in; sign in there.
4. Confirm Steam accepts the game request and Champagne shows its download
   progress. Avoid any purchase prompt.
5. Restart Champagne during the download and confirm its status returns.
6. When Steam finishes, confirm the game appears in the library and launches.

Record which step fails, the visible message, and whether Steam shows an
ownership or install prompt. A screenshot may include account names, so remove
those before sharing it.
