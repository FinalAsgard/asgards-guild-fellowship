# Asgard's Guild Fellowship

A World of Warcraft add-on for the guild's member database and Fellowship roster: who each player is, which characters are their mains and alts, and the alias they choose to be called. It supports WoW Forever and WoW Retail from one source tree.

The add-on groups the guild's characters into **players**. Each player has one main, any number of alts, and an optional alias. The grouping is seeded from public guild notes, and from then on it's kept in a local database. You change it by hand, and officers' edits reach it through [guild sync](#guild-sync).

## Installing

Install **Asgard's Guild Fellowship** from CurseForge, for example with the CurseForge app. One download works on both supported clients, WoW Forever and WoW Retail (see [Supported clients](#supported-clients)). To install by hand, unzip the release into your client's `Interface\AddOns` folder so that you have `Interface\AddOns\AsgardsGuildFellowship`.

## Commands

| Command | What it does |
|---|---|
| `/agf` or `/agf roster` | Shows or hides the roster window. |
| `/agf rescan` | Scans the guild's notes right away. |
| `/agf options` | Opens the add-on's settings panel. |
| `/agf minimap` | Hides the minimap button, or brings it back. |
| `/agf tags` | Turns chat tags off, or back on. |
| `/agf sync` | Shows guild sync status: whether it's running or paused, when you last synced, and how many of your suggestions are waiting for an officer. |
| `/agf help` | Lists the commands, with the version, client, and library status. |

## Settings

The add-on has a settings panel at **Esc → Options → AddOns → Asgard's Guild Fellowship** (`/agf options` opens it). It has one section per feature:

- **General**: show or hide the minimap button, an **Open Roster** button, and the version you're running.
- **Chat Tags**: turn chat tags on or off.
- **Guild Greet**: turn Guild Greet on or off.

The panel and the slash commands change the same settings, so a change made either way shows up in both. Settings are saved for every character on this game install. The development build's panel is labeled "(Dev)".

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
- After that, a note that disagrees with the database never overwrites it. The difference goes to the **conflict queue** instead. One exception: a note's alias is filled in for a player with no alias, as long as nobody ever set or cleared one by hand or through sync. An alias someone deliberately removed is never brought back by a note, and a note naming a different alias than the player has is still a conflict. A conflict like this left over from an earlier version is filled in the next time you use **Rescan**, or you can accept it. You'll also find in the queue any note naming a character that doesn't exist or matches more than one, and any note that loops back on itself.
- **Conflicts (N)** at the bottom of the window opens the queue. Each entry shows the note and what it suggests next to what the database says. Accept or reject each one, or all at once.
- A rejected suggestion stays away until that note changes again.
- Officer data from [guild sync](#guild-sync) beats guild notes. On a new install, notes fill in the roster first, and officer edits replace them where the two disagree. After an officer edit arrives, the next scan checks the notes it affects again. A note that disagrees goes to the conflict queue, and a pending conflict the edit already settled disappears.

### Mains, alts, and departures

- A player always leads with a character who is in the guild. If their main leaves, or a note names a main outside the guild, an in-guild alt becomes the acting main: the highest level, then the most recently online. You confirm that change in the conflict queue.
- Characters who leave are kept and marked departed. They're hidden until you choose **Show departed**. A returning character goes back to their old player automatically.
- **Purge** removes one departed character. **Purge all departed** removes them all.

### Organizing by hand

Right-click a character for **Set main…**, **Make this the main**, **Set alias…**, **Detach as own player**, and **View player…**. Clicking a character also opens the player panel. It shows the alias, main, alts, and history, and has **Set alias…** and **Set main…** buttons that open the same dialogs as the menu. History lists characters that left the player: ones that left the guild, were detached, or were moved to another player.

Changes show up right away and are recorded as manual. An officer's changes then reach the rest of the guild through [guild sync](#guild-sync), and a member's are sent to officers as [suggestions](#suggestions). The player panel also has the **Don't sync** checkbox (see [Don't sync](#dont-sync)). Data is saved per guild and shared by every character on this game install.

### Finding people

- The search box matches character names and aliases.
- **Online only** hides players with no character online.
- **Expand all** and **Collapse all** open and close every group.
- Online players come first, then everyone else by name. A group shows "online as …" when the player is on an alt.
- A player with one character is shown as a single row.

## Guild sync

When an officer changes which characters belong together, or what a player goes by, the change reaches everyone in the guild who runs the add-on and is online. This covers **Set main…**, **Make this the main**, **Detach as own player**, and **Set alias…**, including clearing an alias. Officers' edits update your roster and chat tags without a rescan.

- An officer is anyone whose guild rank can view officer notes. The guild master always counts. Nothing needs to be set up: promoting or demoting someone changes what their edits do.
- When two officers change the same character or the same alias, the most recent edit wins everywhere.
- A member's own edits apply in their roster right away and are sent to officers as suggestions (see [Suggestions](#suggestions)). Only officers' edits change everyone's roster directly.
- Edits made before sync existed: they become official and are sent to the guild once you log in on an officer character with this version. Until then, and for members, they stay in your own roster only.
- Only main and alt links and aliases are shared. Departures, purges, history, conflicts, and settings stay on your computer.
- Sync messages go out at the game's lowest add-on priority, so they never hold up chat or other add-ons.
- The roster window's footer shows when you last synced, meaning the last time your add-on compared or exchanged officers' data with another add-on user. `/agf sync` shows the same, plus whether sync is paused and how many of your suggestions are waiting.
- Sync never gets in the way of play. It sends and processes nothing while you're in combat, or on Retail during a boss encounter or a keystone run, and picks up where it left off once that's over. Like scans, it works on data a little at a time, so even a large guild's full sync doesn't cause a hitch, and your roster window redraws once per batch rather than once per change.

### Suggestions

Members know their own alts best, so a member's edits become suggestions for the officers:

- When you're not an officer, **Set main…**, **Make this the main**, **Detach as own player**, and **Set alias…** still change your roster at once. Each change is also kept as a suggestion.
- Suggestions go to the guild as soon as an officer is online. If none is, they wait, and are sent when an officer logs in.
- Officers find them in their conflict queue, marked "Suggested by" and the member's name. **Accept** and **Reject** work as for any other entry, and so do Accept all and Reject all.
- The first officer to decide settles the suggestion for every officer, and it disappears from the other officers' queues. Accepting makes it an official edit under that officer's name, which reaches everyone.
- Rejecting puts your roster back the way the officers have it, so you stay on the same data as everyone else. If no officer ever set that character or alias, it goes back to what the guild notes and the roster say.
- Until then, your edit stays in your roster unless a newer officer edit about the same character or alias arrives.
- Your suggestions that are still waiting are listed at the bottom of your **Conflicts** window, marked "Your suggestion" and "Waiting for an officer". They aren't counted on the Conflicts button, and they leave the list once an officer decides them. Suggestions are only sent while you're online, so if you log off before an officer decides, yours are sent again the next time an officer is online.

### Don't sync

To keep your own version of a player, open the player panel and check **Don't sync**. The panel's title and the checkbox show the player in orange while it's on.

- Officers' edits for that player are ignored on your computer: moving its characters in or out, changing its main, and setting or clearing its alias.
- Every other player keeps syncing as usual.
- Uncheck it to rejoin. Your own edits to that player stop counting as newer than the officers', and your add-on asks the guild for their data right away, so the player matches what the officers have within a few seconds if anyone online has it, or at your next login otherwise.

### Catching up when you log in

You don't need to be online at the same time as an officer. Officers' edits also reach you through other add-on users:

- About 30 to 60 seconds after you log in, your add-on asks the guild whether your copy of officers' data matches theirs. It sends a short summary, never the data itself.
- If someone's copy is the same, nothing else is sent. If it differs, one add-on user who has the officers' edits sends back only the part that differs. That can be any member, but an online officer answers first. If you hold officer edits they're missing, yours go back the other way.

### How sync protects your data

Any add-on user can pass officers' edits on, so the add-on checks what it receives:

- An edit is only accepted when the officer it names holds an officer rank on the current roster. A member can't make their own edits official by passing them on.
- An edit dated more than a few minutes in the future is refused, so a faked date can't make an edit win over every real one.
- When an officer is online, your data is checked against theirs directly. Officers answer catch-up requests before members do, and the game guarantees who sent each message, so differences come from the officer's own copy.
- Each officer's add-on keeps a ledger of the edits that officer made. If someone passes on an edit in an officer's name that the officer never made, that officer's add-on catches it as soon as it sees it. That happens either right away, or when the officer next logs in and checks the guild's data. The add-on refuses the edit, sends the officer's own data to the whole guild to replace it, and logs which character passed it on. It also warns the officer in chat.
- A forged edit can only last until the officer it names is online again. Edits dated before an officer's add-on started its ledger, including ones from before this version, are trusted.
- The ledger is kept in that computer's saved data. If you're an officer who plays on two computers, an edit you made on one can look forged to the other, which then puts back its own data. Make officer edits on one computer.

## Chat tags

In guild chat, officer chat, and guild achievement announcements, a tag after the speaker's name shows who the player is:

- If the player has an alias, the tag shows it: Hammer (an alt of Toolbox, alias TheTool) saying hi reads `[Hammer] [TheTool]: hi`.
- If they have no alias and are on an alt, the tag shows their main's name: `[Wrench] [Toolbox]: hi`. If the main has left the guild, it's the acting main.
- Achievements read the same way: `[Hammer] [TheTool] has earned the achievement …`.
- There's no tag when they're on their main with no alias, or when the tag would just repeat their own name.

An alias tag is medium blue and a main's-name tag is light blue, so you can tell a nickname from a character name at a glance. Your own messages are tagged the same way. Characters the database doesn't know yet get no tag. The name stays clickable as usual. Tags come from your own database, so changes you make in the roster show up on the next line.

Tags are on by default. `/agf tags` or the **Chat Tags** section of the settings panel turns them off, and doing it again turns them back on. The choice is saved for every character on this game install and applies from the next chat line.

On Retail, the game hides chat from add-ons during encounters and keystone runs. Those lines appear without tags, and tags return once the restriction lifts.

## Guild Greet

When a guild member comes online, a small prompt appears at the right side of the screen with the name they go by and a **Greet** button. Press it to post a random greeting to guild chat. Nothing is ever posted unless you press the button.

- **Login**: the first time you see someone come online this session.
- **Welcome back**: someone you saw log off comes back 15 minutes or more later. Coming back sooner (a relog or a disconnect) gets no prompt.
- People who were already online when you logged in, your own characters, and friends outside the guild never get a prompt.
- Greet works per player, so switching from a main to an alt is the same person, not a new arrival.
- Prompts disappear after 2 minutes; the **X** closes one without greeting.

Greetings can use `{name}` (the player's alias, else their main's name, else the character's name) and `{character}` (the character that just logged in). Starter greetings are included. The same greeting is never picked twice in a row. Guild Greet is on by default; turn it off in the **Guild Greet** section of the settings panel. Greetings and the setting are shared by every character on this game install.

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

The add-on uses LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0, LibSharedMedia-3.0, the Details! Framework, AceSerializer-3.0, and AceComm-3.0 (which brings ChatThrottleLib). They are not committed. [`tools/libraries.txt`](tools/libraries.txt) pins each one to a tag, and both release packages (`.pkgmeta` externals) and development checkouts use those pins. To fetch them into the git-ignored `Libs/` folder, run this in PowerShell (Windows PowerShell or `pwsh`):

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
