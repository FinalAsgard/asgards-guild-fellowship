# Asgard's Guild Fellowship

A World of Warcraft add-on for the guild's member database and Fellowship roster: who each player is, which characters are their mains and alts, and the alias they choose to be called. It supports WoW Forever and WoW Retail from one source tree.

This is an early foundation. The add-on loads, detects the running client, and answers `/agf help` (`/agfdev help` in the development build) with its version, client, and library status. Roster features come in later releases.

## Supported clients

| Client | Production manifest | Development manifest |
|---|---|---|
| WoW Forever | `AsgardsGuildFellowship_Camelot.toc` | `AsgardsGuildFellowshipDev_Camelot.toc` |
| WoW Retail | `AsgardsGuildFellowship_Mainline.toc` | `AsgardsGuildFellowshipDev_Mainline.toc` |

On any other client the add-on prints one message, keeps `help` working, and leaves saved data untouched.

The development build uses its own folder (`AsgardsGuildFellowshipDev`), commands, chat tag, and SavedVariables, so it never mixes with a production install.

## Project layout

- `Core/` is game-independent Lua.
- `Adapters/` is the only code that touches WoW APIs.
- `AsgardsGuildFellowship.lua` builds the modules in order.

## Libraries

The add-on uses LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0, LibSharedMedia-3.0, and the Details! Framework. They are not committed. [`tools/libraries.txt`](tools/libraries.txt) pins each one to a tag, and both release packages (`.pkgmeta` externals) and development checkouts use those pins. To fetch them into the git-ignored `Libs/` folder, run this in PowerShell (Windows PowerShell or `pwsh`):

```powershell
./tools/Fetch-Libraries.ps1
```

Run it again any time; it only downloads a library whose pin changed. To change a pin, edit `tools/libraries.txt` and `.pkgmeta` together. CI runs `lua5.1 tools/check-libraries.lua`, which fails when they differ.

If a library is missing in game, the add-on prints one message naming it, and `help` lists which libraries are present.

## Development install (Windows)

The development add-on is a directory junction, `Interface\AddOns\AsgardsGuildFellowshipDev`, that points straight at your git checkout. From PowerShell in the checkout:

```powershell
./tools/Install-Dev.ps1                 # WoW Forever (default)
./tools/Install-Dev.ps1 -Client Retail  # WoW Retail
```

The installer fetches the libraries first, so you don't need to run `tools/Fetch-Libraries.ps1` yourself. If the fetch fails, nothing is linked. After a new install, restart WoW so it finds **Asgard's Guild Fellowship (Dev)**.

| `-Client` | Default client directory |
|---|---|
| `Forever` (default) | `C:\Program Files (x86)\World of Warcraft\_classic_beta_` |
| `Retail` | `C:\Program Files (x86)\World of Warcraft\_retail_` |

If WoW is installed somewhere else, pass the `World of Warcraft` folder with `-WowInstallRoot`; `-Client` still picks the client directory inside it. For an unusual layout, pass the exact client directory with `-WowRoot`, which overrides the derived one:

```powershell
./tools/Install-Dev.ps1 -Client Retail -WowInstallRoot "D:\World of Warcraft"
./tools/Install-Dev.ps1 -Client Forever -WowRoot "D:\Games\WoW Forever"
```

To develop against both clients, run the installer once per client. Both junctions point at the same checkout.

The installer is safe to run again. If the junction already points at this checkout, it reports "already linked" and changes nothing. It refuses, without changing anything, if `AsgardsGuildFellowshipDev` is a real folder or a junction pointing somewhere else. It never edits repository files or changes permissions.

### Updating

There is no copy step. Pull, then reload:

```powershell
git pull --ff-only
./tools/Fetch-Libraries.ps1   # only downloads libraries whose pins changed
```

Use `/reload` in game for Lua changes, and restart WoW after manifest changes.

### Keeping production and development apart

The production add-on lives in `AsgardsGuildFellowship` (managed by CurseForge) and the development add-on in `AsgardsGuildFellowshipDev`. They never overwrite each other. Each build has its own commands (`/agf` and `/agfdev`) and its own SavedVariables (`AsgardsGuildFellowshipDB` and `AsgardsGuildFellowshipDevDB`), so their data never mixes. Enable only one of them at a time.

## Running the tests

The tests need only Lua 5.1:

```sh
lua5.1 tests/run.lua
```

CI runs the same suite, a syntax check of every add-on Lua file, and the library pin check in the `Lua 5.1` job. The tests stand in for the libraries, so they don't need `Libs/`.
