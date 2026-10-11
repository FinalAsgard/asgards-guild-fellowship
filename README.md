# Asgard's Guild Fellowship

A World of Warcraft add-on for the guild's member database and Fellowship roster: who each player is, which characters are their mains and alts, and the alias they choose to be called. It supports WoW Forever and WoW Retail from one source tree.

The add-on groups the guild's characters into **players**. Each player has one main, any number of alts, and an optional alias. The grouping is seeded from public guild notes, and from then on it's kept in a local database. You change it by hand, and officers' edits reach it through [guild sync](#guild-sync).

## Installing

Install **Asgard's Guild Fellowship** from CurseForge, for example with the CurseForge app. One download works on both supported clients, WoW Forever and WoW Retail (see [Supported clients](#supported-clients)). To install by hand, unzip the release into your client's `Interface\AddOns` folder so that you have `Interface\AddOns\AsgardsGuildFellowship`.

## Commands

| Command | What it does |
|---|---|
| `/agf` or `/agf roster` | Opens the add-on's window on the **Roster** tab, or closes it. |
| `/agf rescan` | Scans the guild's notes right away. |
| `/agf recruit` | Opens the window on the **Recruitment** tab. |
| `/agf greet` | Opens the window on the **Greetings** tab, where you edit your Guild Greet greetings. |
| `/agf options` | Opens the window on the **Settings** tab. |
| `/agf minimap` | Hides the minimap button, or brings it back. |
| `/agf tags` | Turns chat tags off, or back on. |
| `/agf channels` | Shows the chat channels Guild Recruit sees where you are: each channel the game lists, whether it's disabled here, and which ones it would post to for General and Trade. |
| `/agf sync` | Shows guild sync status: whether it's running or paused, when you last synced, and how many of your suggestions are waiting for an officer. |
| `/agf help` | Lists the commands, with the version, client, and library status. |

## The add-on's window

Everything the add-on does is in one window, with picture tabs down its right edge. Hover a tab to see its name, and click it to show its page; the tab you're on looks selected. Every page scrolls when it's taller than the window.

- **Roster**: the guild's players, mains and alts (see [Using the roster](#using-the-roster)).
- **Recruitment**: your [Guild Recruit](#guild-recruit) settings, and for officers the guild's settings and the **Recruiters** leaderboard (see [Ad counts](#ad-counts)).
- **Greetings**: Guild Greet's settings, with the greetings editor below them (see [Editing greetings](#editing-greetings)).
- **Settings**: everything else (General and Chat Tags), and the version you're running.

The minimap button, the add-on compartment, the guild window's **Guild Fellowship** button and `/agf` always open the window on the Roster tab, whatever tab you used last. `/agf recruit`, `/agf greet` and `/agf options` open their own tabs. Escape or the close button closes the window. It remembers its size and position (the first time, it starts where the old roster window was), and you can resize it down to a minimum.

## Settings

The settings are in two places that always agree: the window's tabs, and **Esc → Options → AddOns → Asgard's Guild Fellowship**. In the AddOns options, the add-on's own page has an **Open window** button and the version, and each feature has a sub-page of its own under it:

- **General**: show or hide the minimap button, and the version you're running.
- **Chat Tags**: turn chat tags on or off, and choose the colors of the alias tag and the main's-name tag (see [Chat tags](#chat-tags)).
- **Guild Greet**: turn Guild Greet on or off (everywhere, or just on the character you're playing), turn each category's prompts on or off, set the welcome-back minutes and long-absence days, set how many greetings close your prompt, and unlock the prompts to move them. In the AddOns options it also has an **Edit Greetings** button that opens the window's Greetings tab.
- **Recruitment**: turn [Guild Recruit](#guild-recruit) prompts on or off on the character you're playing, write your own ad, choose whether you also post the officers' guild ad (hover the info icon beside it to read the guild ad), and set your own timers (sliders) for how long General and Trade go without a guild ad before you're asked. On a character that can't invite to the guild these are greyed out, with a line saying why. Officers also get the guild ad, the guild's floor under everyone's timers for General and for Trade, and a pause for the whole guild, under their own **Officer settings** heading because they apply to everyone in the guild. Regular members don't see the officer settings.

A change made in the window, the AddOns options or a slash command shows up in the other places at once. Settings are saved for every character on this game install. The development build's options are labeled "(Dev)".

## Using the roster

### Opening it

The roster is the **Roster** tab of [the add-on's window](#the-add-ons-window).

- `/agf` (or `/agf roster`) opens the window on the Roster tab. If it's already showing the Roster tab, it closes the window; on another tab, it switches to Roster. The development build uses `/agfdev`.
- The minimap button does the same. Its tooltip shows how many conflicts are waiting. Drag it to move it; its position is saved. `/agf minimap` hides it, and running it again brings it back.
- On Retail, the add-on compartment has an entry for it as well.
- The guild window gets a **Guild Fellowship** button left of **Invite Member**. If the add-on can't find that button, it skips this one quietly.
- `/agf help` lists the commands with the version, client, and library status.

Opening the window never scans the guild, so it's always quick. The Conflicts window and the player panel open beside the window, and close with it.

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

For a player who has posted recruitment ads, the player panel also shows **Advertised: N (M in last 30 days)** (see [Ad counts](#ad-counts)).

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
- The Roster tab's footer shows when you last synced, meaning the last time your add-on compared or exchanged officers' data with another add-on user. `/agf sync` shows the same, plus whether sync is paused and how many of your suggestions are waiting.
- Sync never gets in the way of play. It sends and processes nothing while you're in combat, or on Retail during a boss encounter or a keystone run, and picks up where it left off once that's over. Like scans, it works on data a little at a time, so even a large guild's full sync doesn't cause a hitch, and your roster redraws once per batch rather than once per change.

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

An alias tag is medium blue and a main's-name tag is light blue, so you can tell a nickname from a character name at a glance. To use other colors, pick one of the swatches beside **Alias tag color** and **Main's name tag color** in the **Chat Tags** settings; a sample tag shows the color chosen. Where the game has a color picker, **Custom...** opens it for any color. The colors are saved for every character on this game install. Your own messages are tagged the same way. Characters the database doesn't know yet get no tag. The name stays clickable as usual. Tags come from your own database, so changes you make in the roster show up on the next line.

Tags are on by default. `/agf tags` or the **Chat Tags** settings turn them off, and doing it again turns them back on. The choice is saved for every character on this game install and applies from the next chat line.

On Retail, the game hides chat from add-ons during encounters and keystone runs. Those lines appear without tags, and tags return once the restriction lifts.

## Guild Greet

When someone joins the guild or a guild member comes online, a small prompt appears (at the left side of the screen unless you move it) with just the name they go by and a **Greet** button. Press it to post a random greeting to guild chat. Nothing is ever posted unless you press the button.

- **Join**: someone joins the guild. They get this instead of a login prompt.
- **Long absence**: someone's first login this session when none of their characters had logged in for 30 days or more (you can change the days), going by the guild roster's last-online times when you logged in.
- **Login**: the first time you see someone come online this session.
- **Welcome back**: someone you saw log off comes back 15 minutes or more later (you can change the minutes). Coming back sooner (a relog or a disconnect) gets no prompt.
- People who were already online when you logged in, your own characters, and friends outside the guild never get a prompt.
- Greet works per player, so switching from a main to an alt is the same person, not a new arrival.
- A prompt shows 5 to 10 seconds (at random) after someone arrives, so your greeting doesn't reach them while their game is still loading. It disappears 2 minutes after it shows; the **X** closes one without greeting.
- To move the prompts, tick **Unlock greet prompts** in the Guild Greet settings and drag the gold bar that appears. The place is saved for every character. The bar stays while the add-on's window is open, on any tab. Untick it, or close the window or the AddOns options, to hide it; it also locks again after a reload.
- In combat or a boss encounter, prompts wait. When it's over, any that are still under 2 minutes old appear.
- On Retail, the game hides some system messages from add-ons during encounters and keystone runs. Logins it hides get no prompt; nothing breaks.

Greetings can use these placeholders, in any capitalization:

| Placeholder | Becomes |
|---|---|
| `{name}` | The player's alias, else their main's name. |
| `{main}` | Their main's name, even when they have an alias. |
| `{mainFirst}`, `{mainLast}` | The first or last part of the main's name. |
| `{character}` | The character that just logged in. |
| `{characterFirst}`, `{characterLast}` | The first or last part of that character's name. |

First and last parts only differ on WoW Forever, where names have two parts, so "Hello Mr. {mainLast}" greets Tool Box as "Hello Mr. Box". On Retail, names are one word, so `{mainFirst}` and `{mainLast}` are the same as `{main}`, and `{characterFirst}` and `{characterLast}` are the same as `{character}`. Starter greetings are included. The same greeting is never picked twice in a row. Guild Greet is on by default; turn it off in the **Guild Greet** settings. Greetings and settings are shared by every character on this game install, and **Guild Greet on this character** turns it off on just the one you're playing, say an alt in another guild.

### Greeting together

When you greet someone, the add-on tells other add-on users in the guild. Once a player has had enough greetings from anyone (2 by default; set it from 1 to 10 in the Guild Greet settings), your prompt for them quietly closes, and you aren't prompted for them again until the welcome-back time (15 minutes unless you changed it) has passed since the last greeting. Each person's greeting counts once, whichever category or character it was for. This only counts members running the add-on; greetings typed by hand aren't seen. If two people press Greet at the same moment, an extra greeting can slip through.

### Editing greetings

Greetings are edited on the window's **Greetings** tab (`/agf greet`, or **Edit Greetings** in the AddOns options), below Guild Greet's settings. The editor has a button for each category. Each lists that category's greetings, with **Edit** beside each one. Type in the box below the list and press **Add** (or Enter) to add a greeting. **Edit** puts a greeting in the box, with **Save**, **Delete** and **Cancel** beside it. A greeting must fit in one guild chat message (255 characters), and blank ones aren't saved. The editor lists every placeholder.

A category with no greetings shows no prompts, so emptying one is a way to turn it off. **Restore starter greetings** puts back the starters in the open category, and **Restore all categories** does it everywhere. Both replace what's there, so each asks for a second click.

## Guild Recruit

Guild Recruit spreads the guild's recruitment ads out: every zone sees the guild now and then, and nobody spams a channel. When you're somewhere the guild hasn't advertised lately, a small **Guild Recruit** window (centered, about a quarter of the way down the screen, so it's never mistaken for a greet prompt) asks **Advertise in Elwynn Forest General?** or **Advertise in Trade?**. Press **Post** to send an ad there. Nothing is ever posted unless you press the button.

### Who gets prompts

- Only characters whose guild rank can invite to the guild. Without that permission there are no prompts, and the Recruitment settings are greyed out.
- The first time you log in on such a character, Guild Recruit asks **Help with guild recruitment?**. **Yes** turns prompts on and **No** turns them off; closing the question asks again next login. Each character has its own answer, and you can change it any time in the **Recruitment** settings.
- If a character loses invite permission, its prompts stop at once, and its answer goes back to undecided at the next login, so you're asked again if it's promoted later.
- You need an ad to post: your own, the officers' guild ad, or both. When both are usable, each post picks one at random. Uncheck **Also post the officers' guild ad** to post only yours. With no usable ad, there are no prompts.

### Channels and timing

- **General**: each zone has its own timer. You're asked to post in a zone's General once it has gone 60 minutes (by default) without a guild ad there.
- **Trade**: one channel in every city, so an ad in one city counts for all of them. You're asked once it has gone 60 minutes (by default) without one. You're only prompted for Trade where the game has you in the Trade channel and can post there. General and Trade are found by their English names, so on a client in another language there are no prompts.
- **Your timers**: set your own General and Trade timers in the **Recruitment** settings, from 5 minutes to 4 hours, to be asked more or less often.
- **The guild's floor**: officers set the shortest time the guild allows between ads, 30 minutes for General and 10 for Trade by default (never below 15 and 5, at most 4 hours). Nobody's timer goes below it, so officers decide how often the guild can advertise. The Recruitment page shows the current floor.
- Officers can also pause recruitment for the whole guild, and turn the guild ad off by clearing it.
- Staying in one place, you're prompted again when a timer runs out.
- **Not now** hides that channel's prompt for 10 minutes. **Off here** stops prompts in the current zone (its General, and Trade while you're there) until you log out or reload.
- Prompts wait during combat, boss encounters, dungeons, raids, battlegrounds, arenas, and keystone runs, and close when you leave the zone or city they're for.
- Ads are posted exactly as written, up to 255 characters. A send the game refuses doesn't count as an ad.

### Advertising together

Add-on users tell each other when and where they advertised, so nobody double-posts:

- When your ad posts, other add-on users record it and their prompt for that channel closes. Prompts wait a few seconds (at random) before showing, so two people rarely get the same one at once.
- When you log in, or enter a zone or city you have no recent time for, your add-on asks the others. If nobody answers within a few seconds, the channel counts as not advertised in. Only one or a few add-ons answer each question.
- Times are saved for each guild, so they last across reloads and logouts, and a relog doesn't prompt you for a channel the guild advertised in within your timer. A saved time older than your timer is asked about again, never taken as the last ad.
- No officer needs to be online, or use the add-on at all: members recruit and coordinate with their own ads and the default timers. The officers' ad, gaps and pause only take effect once an officer sets them, and they're only accepted from officers. The newest change wins.
- Without the add-on's messaging libraries, Guild Recruit still works, going only by your own posts.

### Ad counts

Every post counts toward the player who made it, on all their characters together. The player panel shows **Advertised: N (M in last 30 days)**. The 30-day number falls as ads get older, even if they don't post again. Only ads posted through the add-on are counted.

Officers also get the **Recruiters** leaderboard on the window's **Recruitment** tab (`/agf recruit`), below the settings. It lists every player who has advertised, by alias or main, ranked by ads in the last 30 days and then all time. Below that, **Recent ads** lists each channel your add-on knows was advertised in lately (for example "Elwynn Forest General" or "Trade") and how long ago, newest first. Ad times are kept for 4 hours, across reloads and logouts, so a relog never forgets where the guild just advertised. Both parts update as new ads arrive. Regular members don't see the leaderboard.

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
