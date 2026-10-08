# Asgard's Guild Fellowship

A World of Warcraft add-on for the guild's member database and Fellowship roster: who each player is, which characters are their mains and alts, and the alias they choose to be called. It supports WoW Forever and WoW Retail from one source tree.

The add-on groups the guild's characters into **players**. Each player has one main, any number of alts, and an optional alias. The grouping is seeded from public guild notes, and from then on it's kept in a local database that only you change.

## Installing

Install **Asgard's Guild Fellowship** from CurseForge, for example with the CurseForge app. One download works on both supported clients, WoW Forever and WoW Retail (see [Supported clients](#supported-clients)). To install by hand, unzip the release into your client's `Interface\AddOns` folder so that you have `Interface\AddOns\AsgardsGuildFellowship`.

## Commands

| Command | What it does |
|---|---|
| `/agf` or `/agf roster` | Shows or hides the roster window. |
| `/agf rescan` | Scans the guild's notes right away. |
| `/agf minimap` | Hides the minimap button, or brings it back. |
| `/agf help` | Lists the commands, with the version, client, and library status. |

## Using the roster

### Opening it

- `/agf` (or `/agf roster`) shows or hides the roster window. The development build uses `/agfdev`.
- The minimap button toggles it too. Its tooltip shows how many conflicts are waiting. Drag it to move it; its position is saved. `/agf minimap` hides it, and running it again brings it back.
- On Retail, the add-on compartment has an entry for it as well.
- The guild window gets a **Guild Fellowship** button left of **Invite Member**. If the add-on can't find that button, it skips this one quietly.
- `/agf help` lists the commands with the version, client, and library status.

Opening the window never scans the guild, so it's always quick. The window remembers its position and size, and Escape closes it.

### The guild note convention

Two markers in a character's **public** note seed the database:

- `Main: Toolbox` or the shorter `>Toolbox` means "this character is an alt of Toolbox".
- `Alias: TheTool` or the shorter `@TheTool` means "this player goes by TheTool".

A marker can sit anywhere in the note (for example `Tank, Main: Toolbox, Alias: TheTool`, `Tank >Toolbox` or `@TheTool raid lead`), and both kinds can appear in one note. Only the first main marker and the first alias marker count. The `Main:` and `Alias:` labels can be any case (`main:` works too), the space after the colon is optional, and a label only counts as a word of its own (`Domain:` isn't a main marker). Matching ignores case.

- On **WoW Forever**, names have a first and last name: `Main: Tool Box` and `>Tool Box` work. So do `Main: Tool` and `>Tool`, as long as only one guild character has the first name Tool.
- On **Retail**, `Main: Toolbox` and `>Toolbox` use the single character name. A realm suffix is optional.

An alias from a note is one word: letters (accented ones too), digits, `_`, `'`, and `-`. Longer aliases can be set in the window, up to 48 characters.

The add-on never writes to guild notes.

### Scanning

- On login, the add-on scans every note if the last full scan is more than a day old.
- New members are picked up automatically when the guild roster updates.
- **Rescan** in the window, or `/agf rescan`, scans right away.

Scans run a little at a time, so even a large guild doesn't cause a hitch. The window's footer shows when the last scan ran and what it found.

### The database is the source of truth

- On the first scan, note markers are applied directly to any character the database doesn't know about.
- After that, a note that disagrees with the database never overwrites it. The difference goes to the **conflict queue** instead. You'll also find there any note naming a character that doesn't exist or matches more than one, and any note that loops back on itself.
- **Conflicts (N)** at the bottom of the window opens the queue. Each entry shows the note and what it suggests next to what the database says. Accept or reject each one, or all at once.
- A rejected suggestion stays away until that note changes again.

### Mains, alts, and departures

- A player always leads with a character who is in the guild. If their main leaves, or a note names a main outside the guild, an in-guild alt becomes the acting main: the highest level, then the most recently online. You confirm that change in the conflict queue.
- Characters who leave are kept and marked departed. They're hidden until you choose **Show departed**. A returning character goes back to their old player automatically.
- **Purge** removes one departed character. **Purge all departed** removes them all.

### Organizing by hand

Right-click a character for **Set main…**, **Make this the main**, **Set alias…**, **Detach as own player**, and **View player…**. Clicking a character also opens the player panel. It shows the alias, main, alts, and history, and has **Set alias…** and **Set main…** buttons that open the same dialogs as the menu. History lists characters that left the player: ones that left the guild, were detached, or were moved to another player.

Changes show up right away and are recorded as manual. Data is saved per guild and shared by every character on this game install.

### Finding people

- The search box matches character names and aliases.
- **Online only** hides players with no character online.
- **Expand all** and **Collapse all** open and close every group.
- Online players come first, then everyone else by name. A group shows "online as …" when the player is on an alt.
- A player with one character is shown as a single row.

## Chat tags

In guild chat, a tag after the speaker's name shows who the player is:

- If the player has an alias, the tag shows it: Hammer (an alt of Toolbox, alias TheTool) saying hi reads `[Hammer] [TheTool]: hi`.
- If they have no alias and are on an alt, the tag shows their main's name: `[Wrench] [Toolbox]: hi`. If the main has left the guild, it's the acting main.
- There's no tag when they're on their main with no alias, or when the tag would just repeat their own name.

An alias tag is green and a main's-name tag is light blue, so you can tell a nickname from a character name at a glance. Your own messages are tagged the same way. Characters the database doesn't know yet get no tag. The name stays clickable as usual. Tags come from your own database, so changes you make in the roster show up on the next line.

## Supported clients

| Client | Production manifest | Development manifest |
|---|---|---|
| WoW Forever | `AsgardsGuildFellowship_Camelot.toc` | `AsgardsGuildFellowshipDev_Camelot.toc` |
| WoW Retail | `AsgardsGuildFellowship_Mainline.toc` | `AsgardsGuildFellowshipDev_Mainline.toc` |

On any other client the add-on prints one message, keeps `help` working, and leaves saved data untouched.

The development build uses its own folder (`AsgardsGuildFellowshipDev`), commands, chat tag, and SavedVariables, so it never mixes with a production install.

## For maintainers

The rest of this page is for people working on the add-on. To work on it in game, see [Development install (Windows)](#development-install-windows). To build a package or publish a release to CurseForge, see [docs/packaging.md](https://github.com/FinalAsgard/asgards-guild-fellowship/blob/main/docs/packaging.md).

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

If a library is missing in game, the add-on prints one message naming it, and `help` lists which libraries are present. WoW Forever also shows its own "Error loading …" message for the first library file the manifest lists but can't find. That message comes from the game client, before any add-on code runs, and the add-on can't suppress it. Retail skips missing files silently. Release packages and the dev installer always include the libraries, so you only see this if `Libs/` is missing or incomplete.

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

The release tools have their own shell tests in `tests/tools/` (run any of them directly, for example `tests/tools/set-interface.test.sh`). CI runs them in the **Release package** job; see [docs/packaging.md](https://github.com/FinalAsgard/asgards-guild-fellowship/blob/main/docs/packaging.md).
