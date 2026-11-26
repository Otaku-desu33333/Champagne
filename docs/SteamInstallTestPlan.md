# Direct Steam install check

The app build is ready for a Mac end-to-end check. This uses the user's Steam
account only in Champagne's SteamCMD prompts and, if the game requires it, in
the managed Windows Steam client at first launch. Do not share passwords or
Steam Guard codes in diagnostics.

1. Select the `ChampagneAppOnly` Xcode scheme and run Champagne.
2. In Discover, choose a small Windows game already owned by the test account
   and select **Install in Champagne**.
3. Confirm Champagne creates the managed game environment and Steam client
   without opening a setup wizard.
4. Enter the Steam account name in Champagne. Enter the password or
   authenticator code only in Champagne's secure prompt.
5. Confirm Champagne shows a direct download progress bar while Steam's Windows
   client download UI stays closed. Stop if the account cannot install the game;
   do not approve a purchase.
6. Quit and reopen Champagne during a download. Select the same game again and
   check that SteamCMD resumes the partial files rather than starting over.
7. After download completion, confirm the game appears in Champagne's library.
   Launch it and check whether the managed Steam client asks for sign-in or
   downloads the game data again.
8. Restart Champagne and confirm the installed game remains in the library.

Record the failed step and the visible message. Redact Steam account names and
any codes from screenshots before sharing them.
