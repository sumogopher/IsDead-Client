# IsDead-Client

The IsDead WoW client files, served to every player's **IsDead Launcher**.
The launcher compares each file's SHA-256 with `manifest.json`, downloads
only what changed, removes files that are no longer shipped, clears the
Cache folder when a patch changes, and starts the game.

## What's in it

| Path in `files/` (= the WoW folder) | What |
|---|---|
| `Data/enUS/patch-enUS-W.MPQ` | IsDead / World Tiers patch (spells, items, logo). Put into the player's own language folder automatically (enGB etc.) |
| `Data/patch-Z.MPQ` | All Races All Classes (mod-arac) client patch (renamed from Patch-A so HD packs can use that name) |
| `Interface/AddOns/WorldTiers/` | World Tiers addon |
| `Interface/AddOns/Atlas/` | Atlas 1.16.1 (dungeon and raid maps) |
| `IsDeadLauncher.ps1` | the launcher; updates itself |
| `IsDead Launcher.bat` | what players double-click (never replaced while running) |

## First-time setup (admin, once)

1. Install Git for Windows: https://git-scm.com/download/win
2. On github.com, create a new **Public** repository named `IsDead-Client`
   (no README, no .gitignore). It has to be public so launchers can download
   without a password.
3. Open `config.json`:
   - `owner`: your GitHub user name
   - `realmlist`: your server's address (optional). When set, the launcher
     writes it into players' realmlist.wtf every start.
   - `news`: optional line the launcher prints after updating.
4. Double-click `publish.bat`. Git asks you to sign in to GitHub the first
   time (a browser window).
5. Give players this link:
   `https://github.com/<owner>/IsDead-Client/raw/main/IsDead-Launcher.zip`
   plus PLAYER-SETUP.txt (also inside that zip).

## Every update after that

1. Copy the new client files over `files/` (same layout: Data\..., Interface\AddOns\...).
2. Double-click `publish.bat`.

The version shown to players comes from `WorldTiers.toc` (`## Version:`).
The server's `WorldTiers.Client.Version` (world_tiers.conf) should match it:
players with older files get an in-game "out of date" message.

## Notes

- GitHub caps single files at 100 MB; everything here is far below that.
- `.gitattributes` turns off line-ending conversion, so file hashes stay exact.
- If your server runs a different mod-arac build, replace `files/Data/patch-Z.MPQ`
  with the Patch-A.MPQ from your mod-arac folder (renamed to patch-Z.MPQ).
- Licenses: mod-arac is AGPL-3.0 and Atlas GPL-2.0 (see `licenses/`); both
  allow redistributing them this way.
