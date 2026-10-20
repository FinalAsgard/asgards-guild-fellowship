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
| `/agf group` | Opens the window on the **Group Finder** tab (see [Group Finder](#group-finder)), or closes it. |
| `/agf profile` | Opens the window on the **My Profile** tab (see [My Profile](#my-profile)), or closes it. |
| `/agf dnd` | Turns Group Finder [Do Not Disturb](#do-not-disturb) on, or back off. |
| `/agf advertise` | Posts your guild ad to General where you are, now. `/agf advertise trade` posts it to Trade. Works in a macro. Won't post again before your timer allows (see [Guild Recruit](#channels-and-timing)). |
| `/agf channels` | Shows the chat channels Guild Recruit sees where you are: each channel the game lists, whether it's disabled here, and which ones it would post to for General and Trade. |
| `/agf mail` | Opens [Guild Mail](#guild-mail), to mail the guild ranks you pick (officers only). |
| `/agf sync` | Shows guild sync status: whether it's running or paused, when you last synced, and how many of your suggestions are waiting for an officer. |
| `/agf setdate join\|rank <character> <YYYY-MM-DD>` | Sets a character's join date, or the date it reached its current rank, when you know better than the add-on (officers only; see [Dates behind the checks](#dates-behind-the-checks)). |
| `/agf probe log`, `/agf probe officer`, `/agf probe promote <character>` | Reports what the game gives the add-on: the guild event log, the officer channel, or a dry run of **Promote** for one character (officers only). |
| `/agf help` | Lists the commands, with the version, client, and library status. |

## The add-on's window

Everything the add-on does is in one window, with picture tabs down its right edge. Hover a tab to see its name, and click it to show its page; the tab you're on looks selected. Every page scrolls when it's taller than the window.

- **Roster**: the guild's players, mains and alts (see [Using the roster](#using-the-roster)).
- **My Profile**: your own player, its characters and their role preferences, and Do Not Disturb (see [My Profile](#my-profile)).
- **Group Finder**: build a dungeon group from the guild (see [Group Finder](#group-finder)).
- **Recruitment**: your [Guild Recruit](#guild-recruit) settings, and for officers the guild's settings and the **Recruiters** leaderboard (see [Ad counts](#ad-counts)).
- **Recent Guild Advertisements**: where the guild advertised lately, who posted, and how long ago (see [Ad counts](#ad-counts)).
- **Greetings**: Guild Greet's settings, with the greetings editor below them (see [Editing greetings](#editing-greetings)).
- **Promotions** (officers only): who is ready to move up a rank, each character's checklist, and each rank's requirements (see [Promotions](#promotions)). Its tab shows how many characters are ready.
- **Guild Log** (officers only): the guild's long-term record of joins, invites, leaves, kicks, promotions and demotions (see [Guild Log](#guild-log)).
- **Settings**: everything else (General, Chat Tags, Guild Map, and the Group Finder's Do Not Disturb), and the version you're running.

The minimap button, the add-on compartment, the guild window's **Guild Fellowship** button and `/agf` always open the window on the Roster tab, whatever tab you used last. `/agf group`, `/agf profile`, `/agf recruit`, `/agf greet` and `/agf options` open their own tabs. Escape or the close button closes the window. It remembers its size and position (the first time, it starts where the old roster window was), and you can resize it down to a minimum.

## Settings

The settings are in two places that always agree: the window's tabs, and **Esc → Options → AddOns → Asgard's Guild Fellowship**. In the AddOns options, the add-on's own page has an **Open window** button and the version, and each feature has a sub-page of its own under it:

- **General**: show or hide the minimap button, and the version you're running.
- **Chat Tags**: turn chat tags on or off, and choose the colors of the alias tag and the main's-name tag (see [Chat tags](#chat-tags)).
- **Guild Map**: **Share my location with the guild** and **Show guildmates on the map and minimap**, both on unless you turn them off (see [Guild map](#guild-map)).
- **Guild Greet**: at the top, turn Guild Greet on or off (everywhere, or just on the character you're playing) and unlock the prompts to move them; under **Which arrivals to prompt for**, turn each category's prompts on or off; under **Timing**, set the welcome-back minutes and long-absence days and how many greetings close your prompt. On the window's Greetings tab the greetings editor follows, under its own **Greetings** heading. In the AddOns options it also has an **Edit Greetings** button that opens the window's Greetings tab.
- **Recruitment**: how many guild ads you've posted (all your characters together, and in the last 30 days), then turn [Guild Recruit](#guild-recruit) prompts on or off on the character you're playing, write your own ad, choose whether you also post the officers' guild ad (hover the info icon beside it to read the guild ad), and set your own timers (sliders) for how long General and Trade go without a guild ad before you're asked. On a character that can't invite to the guild these are greyed out, with a line saying why. Officers also get the guild ad, the guild's floor under everyone's timers for General and for Trade, and a pause for the whole guild, under their own **Officer settings** heading because they apply to everyone in the guild. Regular members don't see the officer settings.

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

### Guild size

A line above the roster gives the guild's size, whatever the search and filters, for example **320 players (27 known + 293 unlinked) · 31 alts · 351 characters**. Departed characters never count.

- A **known** player has two or more linked characters, an alias, or a declared main.
- An **unlinked** character stands alone, with no link, alias or declared main. It counts as a player of its own until it's linked, though it may be someone's alt. Linking it moves it from players to alts.
- Hover the line for the breakdown, how many players were active (online, or last online) within 7, 30 and 90 days, who is online now, and how many players have an alias or a declared main.

### The guild note convention

Two markers in a character's **public** note seed the database:

- `Main: Toolbox` or the shorter `>Toolbox` means "this character is an alt of Toolbox".
- `Main: TheTool` or `>TheTool`, naming an alias instead, means "this character is an alt of the player who goes by TheTool", whoever their main is. The alt stays linked when that player changes main, so its note never has to be rewritten.
- `Alias: TheTool` or the shorter `@TheTool` means "this player goes by TheTool".
- `^` at the very start of the note (for example `^ @TheTool raid lead`) means "this is my main, on purpose": a **declared main**, even with no alts. A main marker naming the character itself (`>Toolbox` on Toolbox's own note) says the same at more length. On a character the roster has as someone's alt, either one disagrees with the roster and goes to the conflict queue instead. A `^` anywhere else in the note is just text.

A marker can sit anywhere in the note (for example `Tank, Main: Toolbox, Alias: TheTool`, `Tank >Toolbox` or `@TheTool raid lead`), and both kinds can appear in one note. Only the first main marker and the first alias marker count. The `Main:` and `Alias:` labels can be any case (`main:` works too), the space after the colon is optional, and a label only counts as a word of its own (`Domain:` isn't a main marker). Matching ignores case.

- On **WoW Forever**, names have a first and last name: `Main: Tool Box` and `>Tool Box` work. So do `Main: Tool` and `>Tool`, as long as only one guild character has the first name Tool.
- On **Retail**, `Main: Toolbox` and `>Toolbox` use the single character name. A realm suffix is optional.

An alias from a note is one word: letters (accented ones too), digits, `_`, `'`, and `-`. Longer aliases can be set in the window, up to 48 characters.

A main marker's word is checked against aliases first, then against character names. So when a word is both someone's alias and a character's name, the note links to the player with that alias. Only one-word aliases can be named, upper and lower case don't matter, and on Forever `>Tool` matches the alias Tool before it tries a first name. A main's `@TheTool` and its alts' `>TheTool` link up in the same scan. A main marker naming the player's own alias (`>TheTool` on one of TheTool's characters) changes nothing.

If two players share the alias a note names, or nobody has that alias yet, the add-on doesn't guess: the note goes to the conflict queue. When an alias is set, changed or cleared (from a note, by hand, or through [guild sync](#guild-sync)), those notes are read again on the next scan, so the alt links itself as soon as the alias exists.

The add-on never writes to guild notes.

### Scanning

- On login, the add-on scans every note if the last full scan is more than a day old.
- New members are picked up automatically when the guild roster updates.
- **Rescan** in the window, or `/agf rescan`, scans right away.

Scans run a little at a time, so even a large guild doesn't cause a hitch. The window's footer shows when the last scan ran and what it found.

### The database is the source of truth

- On the first scan, note markers are applied directly to any character the database doesn't know about.
- After that, a note that disagrees with the database never overwrites it. The difference goes to the **conflict queue** instead. One exception: a note's alias is filled in for a player with no alias, as long as nobody ever set or cleared one by hand or through sync. An alias someone deliberately removed is never brought back by a note, and a note naming a different alias than the player has is still a conflict. A conflict like this left over from an earlier version is filled in the next time you use **Rescan**, or you can accept it. You'll also find in the queue any note naming a character that doesn't exist or matches more than one, and any note that loops back on itself.
- **Conflicts (N)** at the bottom of the window opens the queue. Note conflicts are listed under **Note conflicts**: each shows the character, then one wrapped column with the note, what it suggests and what the database says. Accept or reject each one, or all at once. Members' changes are listed above them under **Changes to Player**, one line per player (see [Suggestions](#suggestions)).
- A rejected suggestion stays away until that note changes again.
- Officer data from [guild sync](#guild-sync) beats guild notes. On a new install, notes fill in the roster first, and officer edits replace them where the two disagree. After an officer edit arrives, the next scan checks the notes it affects again. A note that disagrees goes to the conflict queue, and a pending conflict the edit already settled disappears.

### Out-of-date guild notes

Guild notes are how members without the add-on see who's whose alt, and they drift whenever mains, alts or aliases change. Officers see which notes are out of date right in the game's own guild roster (the Communities guild roster, on both clients). Members who aren't officers see nothing new.

- Each member whose public note is out of date gets a small yellow marker at the right of their row.
- Select that member, and a small panel to the right of the game's member details, level with the public note, shows **Should be: …** with the suggested note, then what's wrong with it: **No main marker**, **Main marker names the wrong player**, **Main marker shouldn't be there**, **Alias missing**, **Wrong alias**, or **Main marker can't be read**.
- Retype the suggestion in the game's note editor. The add-on never writes guild notes.

What a note should say:

- An alt points at its own player: `>Alias` and `>Main` both count as correct. A suggestion uses `>Alias` when the player has a one-word alias nobody else in the guild has, and otherwise the shortest form of the main's name that reads back as the right character (a unique first name on Forever).
- A main carries `@Alias` when its player has a one-word alias. A [declared main](#organizing-by-hand)'s note also starts with `^` (a main marker naming itself counts as correct too). On an alt, `^` or a marker naming itself is flagged as naming the wrong player.
- A character on its own, and not declared, has no main marker. An old marker left from before it was split off is flagged.

`Main:` and `Alias:` labels that read correctly count as correct: style alone is never a problem. The suggestion puts the correct markers first and keeps the rest of the note's text after them. Public notes hold 31 characters. When the suggestion would be longer, it shows just the markers, with **Too long for a public note: the other text has to be trimmed.**

**Ignore** hides a mismatch you've chosen to leave alone. It comes back when the note or the add-on's record for that character changes. The list is worked out again after every scan, sync and change in the roster. Departed characters are skipped.

### Mini profile in the guild roster

Select any member in the game's guild roster and, if the add-on knows their player, a small panel under the game's member details shows that player in brief, under their alias and main as the title: their main, then their Discord and location, then their alts one per line, then their bio under **Personal Bio**. Anything they haven't set is left blank. Levels follow each character's name. On your own characters the panel has an **Edit** button that opens [My Profile](#my-profile). Everyone sees it, not just officers.

### Mains, alts, and departures

- A player always leads with a character who is in the guild. If their main leaves, or a note names a main outside the guild, an in-guild alt becomes the acting main: the highest level, then the most recently online. You confirm that change in the conflict queue.
- Characters who leave are kept and marked departed. They're hidden until you choose **Show departed**. A returning character goes back to their old player automatically.
- **Purge** removes one departed character. **Purge all departed** removes them all.

### Organizing by hand

The roster marks a **declared main** (a player who said "this is my main" on purpose) as **(declared main)**, so confirmed players stand apart from characters nobody has organized yet. Players declare their main on [My Profile](#my-profile), or by starting the character's note with `^` (see [The guild note convention](#the-guild-note-convention)). Like the other organizing changes, an officer's declaration is official at once and a member's goes to officers as a [suggestion](#suggestions).

Right-click a character for **Link as alt of…** (makes it an alt of another player), **Make this the main**, **Set alias…**, **Split off as own player** (takes it out of its player into one of its own), and **View player…**. Clicking a character also opens the player panel. It shows the alias, the player's Discord, location and bio under **About** (when they set any; see [About me](#about-me)), main, alts, and history, and has **Set alias…** and **Merge into player…** buttons: **Merge into player…** links the player's main as an alt of another player, the same as **Link as alt of…** on the main. A main that still has alts can't be moved: **Merge into player…** is greyed out and its right-click menu has no **Link as alt of…**. Move its alts or split them off first. History lists characters that left the player: ones that left the guild, were split off, or were moved to another player.

For a player who has posted recruitment ads, the player panel also shows **Advertised: N (M in last 30 days)** (see [Ad counts](#ad-counts)).

Changes show up right away and are recorded as manual. An officer's changes then reach the rest of the guild through [guild sync](#guild-sync), and a member's are sent to officers as [suggestions](#suggestions). The player panel also has the **Don't sync** checkbox (see [Don't sync](#dont-sync)). Data is saved per guild and shared by every character on this game install.

### Finding people

- The search box matches character names, aliases and Discord usernames.
- The **Discord** column shows a player's Discord username, when it's known, on their group's header (or their row, for a player with one character).
- **Online only** hides players with no character online.
- **Expand all** and **Collapse all** open and close every group.
- Online players come first, then everyone else by name. A group shows "online as …" when the player is on an alt.
- A player with one character is shown as a single row.

## Guild sync

When an officer changes which characters belong together, or what a player goes by, the change reaches everyone in the guild who runs the add-on and is online. This covers **Link as alt of…**, **Merge into player…**, **Make this the main**, **Split off as own player**, and **Set alias…**, including clearing an alias. Officers' edits update your roster and chat tags without a rescan.

- An officer is anyone whose guild rank can view officer notes. The guild master always counts. Nothing needs to be set up: promoting or demoting someone changes what their edits do.
- When two officers change the same character or the same alias, the most recent edit wins everywhere.
- A member's own edits apply in their roster right away and are sent to officers as suggestions (see [Suggestions](#suggestions)). Only officers' edits change everyone's roster directly.
- Edits made before sync existed: they become official and are sent to the guild once you log in on an officer character with this version. Until then, and for members, they stay in your own roster only.
- Only main and alt links, aliases, each character's [role preferences](#role-preferences), and each player's [Discord, location and bio](#about-me) are shared. Role preferences and About me are set by the player's own characters, never by officers, and reach the guild at once with no approval. Guildmates who were offline get them through the same catch-up as everything else. Departures, purges, history (including your [group history](#group-history)), conflicts, and settings stay on your computer.
- Sync messages go out at the game's lowest add-on priority, so they never hold up chat or other add-ons.
- The Roster tab's footer shows when you last synced, meaning the last time your add-on compared or exchanged officers' data with another add-on user. `/agf sync` shows the same, plus whether sync is paused and how many of your suggestions are waiting.
- Sync never gets in the way of play. It sends and processes nothing while you're in combat, or on Retail during a boss encounter or a keystone run, and picks up where it left off once that's over. Like scans, it works on data a little at a time, so even a large guild's full sync doesn't cause a hitch, and your roster redraws once per batch rather than once per change.

### Suggestions

Members know their own alts best, so a member's edits become suggestions for the officers:

- When you're not an officer, **Link as alt of…**, **Merge into player…**, **Make this the main**, **Split off as own player**, and **Set alias…** still change your roster at once. Each change is also kept as a suggestion.
- Suggestions go to the guild as soon as an officer is online. If none is, they wait, and are sent when an officer logs in.
- Officers find them in their **Conflicts** window under **Changes to Player**, above **Note conflicts**: one line per player with changes waiting, with how many there are, **Suggested by** (the character that suggested them, with its player's alias or main when that differs, for example "Bolt (Hammer)") and a **Review** button. Suggestions from members on older versions of the add-on are grouped the same way. The Conflicts button and the minimap tooltip count each player's changes once, plus each note conflict.
- **Review** opens a panel beside the window. Its header says who suggested the changes. For every player the changes touch (a member linking their character under someone else's main touches both players), it shows the player as they are now (**Before**) and as they'd be with every change (**Suggested**): main (and whether it's declared), alias, Discord, and each alt on a line of its own. Lines that change are colored: the old value red, the new one green. The live guild note of each character involved is shown below for context. Then each change has its own line in plain words, for example "Bolt: Alt of Toolbox → Alt of Hammer", with **Approve** and **Deny**. **Approve all** and **Deny all** decide the whole player at once, and Accept all and Reject all at the bottom of the Conflicts window still decide everything.
- The first officer to decide settles the suggestion for every officer, and it disappears from the other officers' queues. Accepting makes it an official edit under that officer's name, which reaches everyone.
- Denying puts your roster back the way the officers have it, so you stay on the same data as everyone else. If no officer ever set that character or alias, it goes back to what the guild notes and the roster say.
- Until then, your edit stays in your roster unless a newer officer edit about the same character or alias arrives.
- Your suggestions that are still waiting are listed at the bottom of your **Conflicts** window, marked "Your suggestion" and "Waiting for an officer". They aren't counted on the Conflicts button, and they leave the list once an officer decides them. Suggestions are only sent while you're online, so if you log off before an officer decides, yours are sent again the next time an officer is online.
- All your waiting changes, made from any of your characters, from the roster or from My Profile, form one request for your player. [My Profile](#my-profile) lists them under **Waiting for an officer** in plain words, for example "Wrench as an alt of Hammer" or "Alias: Hammers".
- Changing the same thing again replaces your earlier change in the request. Changing it back to how the officers have it drops it from the request, and from officers' queues.
- **Undo** beside a waiting change puts your roster back the way the officers have it and takes the change back from officers' queues (officers who are offline are told when they next log in). An officer still on an older version of the add-on may keep seeing it until they decide it.
- When an officer decides one of your changes, chat tells you: "An officer approved your change: …" or "An officer denied your change: …". A denial rolls back only that change; the rest of your request keeps waiting.

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

First and last parts only differ on WoW Forever, where names have two parts, so "Hello Mr. {mainLast}" greets Tool Box as "Hello Mr. Box". On Retail, names are one word, so `{mainFirst}` and `{mainLast}` are the same as `{main}`, and `{characterFirst}` and `{characterLast}` are the same as `{character}`. Starter greetings are included. The same greeting is never picked twice in a row. Guild Greet is on by default; turn it off in the **Guild Greet** settings. Greetings and settings are shared by every character on this game install, and **Greet from this character** turns it off on just the one you're playing, say an alt in another guild (hover its info icon for a reminder). Turn off **Greet while in a dungeon, raid or other instance** to get no greet prompts inside dungeons, raids, battlegrounds, arenas and keystone runs. Guildmates who come online while you're inside aren't prompted for later.

### Greeting together

When you greet someone, the add-on tells other add-on users in the guild. Once a player has had enough greetings from anyone (2 by default; set it from 1 to 10 in the Guild Greet settings), your prompt for them quietly closes, and you aren't prompted for them again until the welcome-back time (15 minutes unless you changed it) has passed since the last greeting. Each person's greeting counts once, whichever category or character it was for. This only counts members running the add-on; greetings typed by hand aren't seen. If two people press Greet at the same moment, an extra greeting can slip through.

### Editing greetings

Greetings are edited on the window's **Greetings** tab (`/agf greet`, or **Edit Greetings** in the AddOns options), below Guild Greet's settings. The editor has a button for each category. Each lists that category's greetings, with **Edit** beside each one. Type in the box below the list and press **Add** (or Enter) to add a greeting. **Edit** puts a greeting in the box, with **Save**, **Delete** and **Cancel** beside it. A greeting must fit in one guild chat message (255 characters), and blank ones aren't saved. The editor lists every placeholder.

A category with no greetings shows no prompts, so emptying one is a way to turn it off. **Restore starter greetings** puts back the starters in the open category, and **Restore all categories** does it everywhere. Both replace what's there, so each asks for a second click.

## Guild Recruit

Guild Recruit spreads the guild's recruitment ads out: every zone sees the guild now and then, and nobody spams a channel. When you're somewhere the guild hasn't advertised lately, a small **Guild Recruit** window (centered, about a quarter of the way down the screen, so it's never mistaken for a greet prompt) asks **Advertise in Elwynn Forest General?** or **Advertise in Trade?**. Press **Post** to send an ad there. Nothing is ever posted unless you press the button. Drag the window anywhere you like; it stays where you drop it, across reloads and on every character.

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
- **Not now** hides that channel's prompt for 10 minutes. **Off here** stops prompts in the current zone (its General, and Trade while you're there), on every character, until you turn it back on: the zone is listed on the **Recent Guild Advertisements** page with a **Turn back on** button.
- Prompts wait during combat, boss encounters, dungeons, raids, battlegrounds, arenas, and keystone runs, and close when you leave the zone or city they're for.
- **Advertise on demand**: `/agf advertise` posts your ad to General where you are, and `/agf advertise trade` posts it to Trade. Put either in a macro on your action bar. It works without a prompt, after **Not now** or **Off here**, and in places with no map where you're never prompted (the Deeprun Tram). It counts like any other ad. To prevent spam, it won't post while the guild's last ad in that channel is newer than your timer, and it tells you how long to wait. It also won't post during combat or in an instance, without an ad or invite permission, or while officers have paused recruitment.
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

Officers also get the **Recruiters** leaderboard on the window's **Recruitment** tab (`/agf recruit`), below the settings. It lists every player who has advertised, by alias or main, ranked by ads in the last 30 days and then all time. Regular members don't see the leaderboard.

Everyone gets the window's **Recent Guild Advertisements** tab. It lists each channel your add-on knows was advertised in lately (for example "Elwynn Forest General" or "Trade"), who posted (by alias or main, like the leaderboard), and how long ago, newest first. When your add-on only heard the time from someone running an older version, the poster shows as "not known". Ad times and posters are kept for 4 hours, across reloads and logouts, so a relog never forgets where the guild just advertised. The list updates as new ads arrive.

## Guild Mail

Guild Mail lets an officer send one mail to many guild members at once: launch plans, "come join our Discord", rule changes. You write it once, choose who gets it, check the list, and the add-on sends the mails one at a time while showing progress. It's only for officers: the guild master's rank, or any rank that can view officer notes.

### Opening it

- At a mailbox, officers get a third tab, **Guild Mail**, after Inbox and Send Mail. It lists your guild mails (see [The Guild Mail tab](#the-guild-mail-tab)); **New** and **Edit** open the Guild Mail window next to the mailbox.
- `/agf mail` opens the window anywhere, so you can write and price a mail away from a mailbox. **Send** needs an open mailbox ("Open a mailbox to send"). A non-officer is told that Guild Mail is for officers, and never sees the tab.

### Choosing who gets it

- **Send to these ranks**: tick one or more ranks, in any combination.
- The line below the ranks sums up the other choices, for example "Send to: Mains only · Skip Discord names · Skip inactive". **Edit** opens a panel beside the window to change them:
  - **Mains only**: one mail per player, to their main. A player with no main set gets it on the character the roster treats as their main. A player whose main isn't in a ticked rank gets nothing.
  - **Most recently online character**: one mail per player, to whichever of their characters in a ticked rank was online most recently.
  - **Every character**: one mail to each character in a ticked rank.
  - **Skip players with a Discord name on file**: anyone whose My Profile has a Discord name gets nothing. A player who is on Discord but never filled it in still gets the mail.
  - **Skip characters not online in the last 30 days**.
- Your own characters are always left out, and so are characters who have left the guild.

### Writing it

The subject and message can use the same [placeholders as Guild Greet](#guild-greet), in any capitalization. Each mail fills them in for its own recipient, and `{character}` is the character the mail is sent to. **Preview**, beside **Message**, opens a panel showing the mail exactly as the first ticked recipient will get it, with the list of placeholders.

A mail's subject can be up to 64 characters and its message up to 500, counted after the placeholders are filled in. A recipient whose mail comes out too long is shown with a red warning (for example "subject too long (69/64)"), unticked, and can't be ticked.

### Checking the list and the cost

- **Recipients (42 mails)** shows how many mails will go out. **Edit** beside it opens the list: each character, their player, rank, and when they were last online, each with a check box. Untick anyone to leave them out; the count then reads "40 of 42 mails". Unticked recipients stay unticked, across reloads too.
- At the top of the list, type in **Search names** to show only characters (or players) whose name holds it. **Check All** and **Uncheck All** tick or untick everyone the search shows. To mail just one or two people: **Uncheck All**, search for them, then tick them.
- The cost line shows how many mails and players, and the postage: "42 mails to 38 players · Estimated cost: 12s 60c (30c each)". It updates with every change. At a mailbox it uses the game's own price; away from one it uses the standard 30c.
- Below it is your money. If it isn't enough, the cost turns red and **Send** waits with "Not enough money for postage".

### Sending

- **Send** asks first: "Send 42 mails for 12s 60c postage?". With 20 or more different characters it adds: "The game lets you mail about 20 different characters at a time. The rest will wait for you to resume them later." Then the mails go out one at a time. Each waits for the game to confirm the last one, plus a moment, so the game doesn't drop mails sent too fast. Progress shows as "Sent 17 of 42 · Postage spent: 5s 10c", and each row is marked sent or failed.
- A mail the game rejects is marked failed with the game's reason (for example "Cannot find mail recipient."), and sending moves on.
- The game only lets you mail about 20 different characters in a while (it's anti-spam, and counts every character on your account). When it says "You have reached the in-game cap of unique mail recipients", sending pauses instead: nobody is marked failed, the window says "Paused: the game's mail limit was reached. Try again later.", and **Send** becomes **Resume**. The limit wears off with time; Resume tries the refused mail first and pauses again if it's still in force.
- If the game doesn't answer a mail within 10 seconds, that mail fails ("no response, will try again at the end"), sending moves on, and it's tried once more after the rest. If the game doesn't answer then either, it stays failed.
- If the game blocks the add-on from sending, **Send** becomes **Send next**, and from then on each mail goes out when you click it.
- Closing the mailbox closes the Guild Mail window too.
- **Stop** halts once the mail in flight is answered. **Continue** then sends to everyone still pending, so nobody gets the mail twice, and **End** gives up on them. Closing the mailbox stops sending the same way; reopen it and Guild Mail to continue.
- When it's done, the summary reads "Sent 40 · Failed 2 · Postage spent: 12s", with the failures still listed. Change anything to start a new mail.
- While a send is under way, everything but Send and Stop is locked.

### What's saved

The subject, message, ticked ranks, Send to choice and both skip boxes are saved for every character on your account as you change them, so you can write a mail, log off, and send it later. They come back the first time you open Guild Mail after a reload or relog. A saved rank the guild no longer has is ignored. Anyone you untick in the recipient list stays unticked too, across reloads, until you tick them again or start a **New** mail.

Every send is saved as it goes, for your whole account: once you press Send the mail is locked, and its recipients and how far it got are kept, mail by mail. After a reload, relog or the game closing, the newest unfinished send comes back when you open Guild Mail or the mailbox, on any of your characters (the one resuming pays the postage), and **Continue** sends to whoever is still waiting, so nobody gets it twice. A send paused at the mail limit comes back paused.

If the game closed while a mail was waiting for its answer, nobody knows whether it went: that recipient comes back **unconfirmed** and is never sent again on its own. Open the mail with **View** in the Guild Mail tab and press **Send** to send it again, or **Skip** to leave it.

### The Guild Mail tab

The mailbox's **Guild Mail** tab lists your guild mails:

- Your **draft**, if it has a subject or message, with **Edit** to open it in the window.
- Every mail you've sent, newest first, with its state (Sending, Paused, Paused at the mail limit, Stopped, Done or Cancelled), its progress ("Sent 19 of 42, 2 failed") and when its newest mail went ("last sent 5 min ago"), so you can tell when the mail limit may have worn off.
- **View** opens the mail in the window, read-only: its text, the mail as its first recipient got it, and every recipient with their status, with Send and Skip on an unconfirmed one.
- **Resume** carries on with a mail's waiting recipients (at a mailbox). Only one mail sends at a time, so Resume waits while another is going.
- **Cancel** gives up on a mail's waiting recipients, after asking; nothing more is sent for it. **Remove** takes a finished or cancelled mail off the list, after asking.
- **New** starts a blank mail, asking first ("Discard the current draft?") if the draft has text.
- **Use again** (on the list or on a mail's View page) makes a sent mail your draft: its subject, message, ranks and Send to choices come back with everyone ticked, ready to send to another group. It asks first if your draft has text. The sent mail stays on the list until you **Remove** it, so you can use it again whenever you need it, for example each time someone is promoted to a rank.
- **Welcome mail** opens the guild's [welcome mail](#welcome-mail) settings.

A mail paused at the limit doesn't hold you up: **Edit** your draft and send a new one, and the paused mail waits in the tab to be resumed later.

## Promotions

Each guild rank can have **promotion requirements**: what a character at that rank must do to move up to the next one. Officers set them up and work through them on the window's **Promotions** tab; the rest of the guild only sees their own progress (see [Your own progress](#your-own-progress)). The Promotions and [Guild Log](#guild-log) tabs are only shown to officers (the guild master's rank, or any rank that can view officer notes), and appear or disappear without a reload when someone is promoted or demoted.

### Setting up requirements

Every rank starts with no requirements, so nothing changes until your guild sets them up. On the Promotions tab, **Edit requirements** opens the editor; **Back to list** returns to the list.

- `<` and `>` pick the rank, for example **Member (rank 4)**, with the rank it promotes to beside it. The guild master's rank has no rank above it, so it isn't offered.
- Type the item's name, click the kind button to step through the kinds, type the number for an automated kind, and press **Add** (or Enter). The kinds are:
  - **Checkbox**: an officer ticks it.
  - **Checkbox, needs a note**: ticking it asks for a note (up to 100 characters), such as which event the member attended.
  - **Character days in guild**: this character has been in the guild at least N days.
  - **Player days in guild**: the player has, counted from the earliest join among their characters still in the guild, so a long-time member's new alt doesn't have to wait.
  - **Days at rank**: the character has held its current rank at least N days.
  - **Has the add-on (days)**: any of the player's characters was heard on the add-on within the last N days.
  - **Character level**: the character is at least level N.
- Each item has **Up** and **Down** to reorder it, **Edit** to rename it or change its number (ticks are kept, and everyone is checked again at once), and **Delete**, which asks first because it drops the item's ticks too.
- If the guild master inserts or removes a rank, requirements stay with their rank's position, and the editor warns when the rank there now has a different name, so you can check they still belong.

Requirements reach every add-on in the guild through [guild sync](#guild-sync). When two officers edit the same item, the newest edit wins everywhere. Changes are only taken from an officer's add-on, so nobody else can send one, even in an officer's name. An add-on that logs in catches up from an officer online.

### The Promotions list

The list shows the characters at ranks that have requirements: each with its rank and the rank it would move to, its progress ("3 of 4"), and its player's highest rank on any character when that's higher, so you can see "this is an alt of a rank-5 member" at a glance.

- By default it shows only characters who are **Ready** (every requirement met). Tick **In progress** to add everyone else, and untick a rank's box to hide that rank.
- Search by character name, alias or main. Searching a player shows all their characters.
- Ready characters come first, then by rank, then by name. Long lists come in pages of 50 (`<` and `>`).
- The tab's label shows how many are ready, as **Promotions (4)**, and the tab's icon shows the count too.
- When nobody matches, or no rank has requirements yet, the list says so.
- While the tab is open, it's checked again every 5 minutes, so day-based items catch up.

Click a character to open its checklist:

- **Tick** and **Untick** a checkbox item. A needs-a-note item asks for the note above the list first.
- Automated items show whether they're met and how close the character is: "5 of 7 days", "level 42 of 50", "seen 3 days ago", or "before tracking". An approximate date is marked "(approx.)".
- **Override** passes a failed automated item for this character, with an optional reason. **Undo override** removes it.
- Hover an item to see who ticked or overrode it, when, and the note or reason.

Ticks, notes and overrides reach every officer's add-on through guild sync, including officers who were offline, who catch up when they log in. They're only taken from an officer's add-on, so nobody can tick their own items, even in an officer's name.

### Promoting

The last line of an open checklist promotes the character one rank, if the game lets you promote them.

- When every item is met, **Promote** promotes at once.
- When some aren't, the button reads **Promote...** and asks first, in the window, listing what isn't met. Hover it to see the list.
- The add-on records the date and who promoted. Promotions made in the game's own guild window are recorded too, with the promoter from the guild event log when it has one.
- Any rank change, up or down, from the add-on or the game, clears that character's ticks, notes and overrides. Only the last promotion's date and promoter are kept.
- Where the game doesn't let add-ons promote, the button reads **Mark as promoted**: change the rank in the game's guild window, and the add-on records the promotion when it sees the new rank.

`/agf probe promote <character>` shows whether you may promote a character and what the button would be, without promoting.

### In the player panel and the roster

An officer's player panel has a **Promotion** section: the player's highest rank and earliest join, and for each character its join date, the date it reached its rank, its rank and next rank with progress (and **Ready**), its last promotion ("Promoted on <date> by Thunderer"), and its checklist. **Tick**, **Untick**, **Override**, **Undo override** and **Promote** work from the panel as on the tab. A needs-a-note item, or a promotion that needs confirming, opens the character on the Promotions tab instead, where there's room to type or confirm. The panel and the tab always agree.

On officers' rosters, a character who meets every requirement shows **Ready** before its rank. Members never see it.

### Your own progress

A member sees the Promotion section in their own player panel only: each of their characters' items toward the next rank, with whether each is met and the automated items' progress ("5 of 7 days"). It's read-only, and it never shows notes, who ticked what, or anyone else's progress.

### Dates behind the checks

The automated items use a few dates the add-on keeps for each character, shared with the whole guild so members' own progress is accurate:

- **Joined**: from the guild log when it has the join, else from when the add-on first saw the character in the guild, marked approximate. A character that leaves and comes back counts from its newest join.
- **At this rank since**: from logged promotions and demotions, or from when a scan saw the rank change.
- **Before tracking**: characters already in the guild the first time the add-on scans it count as older than any number of days, so long-standing members don't look like newcomers on day one. A join found in the guild event log replaces it.
- **Add-on heard**: the last time any add-on message came from the character.

Officers who know better can set a date by hand: `/agf setdate join Toolbox 2025-03-14` or `/agf setdate rank Toolbox 2026-09-01`. A date set by an officer wins over the others.

## Guild Log

Officers' add-ons keep a long-term **Guild Log** of the guild's membership: joins, invites (with who invited), leaves, kicks (with who removed them), and promotions and demotions (with who did it, and to which rank). It's read from the game's guild event log, which turns its "3 days ago" ages into dates, and from events the add-on sees as they happen. The same event read more than once, or by several officers, is kept once. Entries are kept forever.

- Officers' add-ons share the log with each other over the officer channel, and catch up when an officer logs in. Members' add-ons never receive or keep it.
- The **Guild Log** tab lists entries newest first: the date, what happened, the character, its player, and who did it.
- **Sort** switches between date and name. **Range** steps through all, the last 7, 30 and 90 days. A check box for each event type (Join, Invite, Leave, Kick, Promote, Demote) shows or hides it.
- Search by character name, alias or main: all of a player's characters show together.
- Long logs come in pages (`<` and `>`), so even thousands of entries stay smooth.

Where the game's guild event log can't be read, everything still works from live events, roster scans, sync and hand-set dates. `/agf probe log` reports what the game's event log gives the add-on, and `/agf probe officer` checks the officer channel.

### Welcome mail

Officers can set up one guild **Welcome mail** for newcomers. **Welcome mail**, beside **New** in the mailbox's Guild Mail tab, opens its page in the Guild Mail window: a subject and message (with the same placeholders and limits), **Save**, and **Send the welcome mail to newcomers**, which starts off. The page shows the welcome as your own character would get it. Saved text is shared with every officer's add-on through guild sync, the newest change winning, so whoever sends it sends the guild's current text. Only officers can change it.

While it's on, a character your add-on first sees in the guild (the "has joined the guild" message, or new in a roster scan) is due a welcome **24 hours** later, so there's time to link an alt. When it's due it's left out if it turns out to belong to someone already in the guild, or already welcomed, even if their other character has since left. Each player gets one welcome, on their main if they have one, else on their first character seen. Someone who left before they were due is dropped. A character the add-on already knew is rejoining, not new, and the guild's very first scan never counts.

Due welcomes collect in a **Welcome mails** row in the Guild Mail tab, and the tab's title counts them: **Guild Mail (3)**. The row reads "Welcome mails: 3 waiting", with **Edit** (the welcome mail's page), **View** and **Send**. Send fills each one in with the welcome mail as it is then, and sends them like any other mail, pausing at the limit and kept across reloads. Each welcome that goes is shared with the other officers' add-ons, which drop that player from their own Welcome mails, so nobody is welcomed twice (unless two officers press Send within seconds of each other). Switching welcome mail off adds nobody new; welcomes already waiting stay until sent or cancelled, and cancelled ones aren't due again.

## Group Finder

The **Group Finder** is a tab of the add-on's window, right below **My Profile**. Click its tab, or type `/agf group` to open the window straight on it (typing it again while it's showing closes the window). Each time the tab comes into view, it checks your level and party again and asks the guild who is around.

The window has three parts: the dungeon picker, or once you've picked one, your group's slots on the left; the groups other guildmates are forming, the guildmates who could join and those nearby on the right; and along the bottom, who else runs the add-on, with a **Do Not Disturb** box.

The window starts with a dungeon picker. The dungeons whose level range includes your character's level are listed first, lowest range first. Tick **Show all** to see the rest too, for a different character or a lower dungeon. Click a dungeon to pick it: it shows at the top as the group's dungeon, with its level range, for example **Dungeon: The Deadmines (17–26)**.

The list and its level ranges come from the game's own Dungeon Finder, on WoW Retail and WoW Forever, so they stay current without add-on updates. Only if the game's Dungeon Finder lists nothing does the add-on fall back to its own list of dungeons with fixed level ranges.

Picking a dungeon starts your group and shows its five slots: 1 tank, 1 healer and 3 DPS. Everyone already in your party, guild members or not, fills a slot, and the slots update as people join or leave:

- On Retail, each party member takes the slot for the role the game assigned them.
- Anyone without an assigned role (everyone on WoW Forever) starts in the first open slot their class can fill: tank, then healer, then DPS. Under **Party roles**, use the **Tank**, **Healer** and **DPS** buttons beside each name (yours included) to put them where they belong. Only the roles their class can play have buttons.

### Changing or ending the group

When all five slots are filled, the window shows **Group complete**. **Change dungeon** takes you back to the list to pick another dungeon, keeping everyone in their slots. **End group** ends the group, and so does leaving the party. Switching to another tab or closing the window doesn't: come back to the Group Finder tab and your group is still there.

### Who could join

Beside the slots, each role that's still open lists the guildmates online right now who could fill it, for example:

**Bolt 22, Hammer 24**

Each player gets one line, listing every character of theirs that fits, each name in its class color (as throughout the window). Hover over the line to see which character they're on and where they are, and click it to whisper that character. A character fits when its level is within the dungeon's range, its class can play the role, and the role is on in its [role preferences](#role-preferences). That includes offline alts, since they can log over. A role already filled lists nobody.

Guildmates whose add-on didn't answer (see [Who is around](#who-is-around)) are listed after the add-on users, and are suggested by what their class can do. They can't get a request, so their line has a **Whisper** button instead of **Request**, and hovering it says so. Guildmates who answered as unavailable (Do Not Disturb, in a group or in an instance) aren't listed, and neither are you or anyone already in your party.

### Requesting a guildmate

Guildmates with the add-on have a **Request** button beside their suggestion. Pressing it sends them a request, and their line shows its state: **pending** until they answer, then **accepted**, **declined**, **expired** (after about 2 minutes with no answer) or **cancelled**. While it's pending the button reads **Cancel**, to withdraw it. **End group** withdraws every pending request.

The guildmate gets a small **Group Finder** prompt: **Toolbox asks you to join The Deadmines (17–26)**, with a button for each way they could join, shown as **Healer — Hammer (24)**. Only roles you still need are offered, only roles that character's preferences allow, and only characters whose level fits the dungeon (alts included). Choosing one puts them in that slot in your window; **Decline** says no. A guildmate in Do Not Disturb, in a group or in an instance declines automatically, as does one with no character that fits. The prompt closes if you cancel or the request expires.

Once someone accepts, getting them into your party is up to you; the add-on never invites anyone on its own. If they're already on the character they chose, its slot has an **Invite** button that sends the game's party invite. If they chose another character, the slot reads **Waiting for Bolt to log in**, and they're reminded in chat to log over to it. The **Invite** button appears as soon as that character is online. When the character joins your party, it fills the slot like any other party member, in the role they chose.

Prompts keep up with your group. When a slot fills, whether someone accepted or joined your party, everyone you've asked loses the options for that role. Anyone left with no option has their prompt closed, and their line in your window shows **withdrawn**. Once every role is filled, the remaining requests are withdrawn too.

Asked by two organizers at once, a guildmate sees both prompts stacked. Accepting one declines the others, and those organizers see **joined another group**.

### Groups being formed

Until you start a group of your own, the right side of the window opens with **Groups forming**: every group a guildmate with the add-on is forming right now, one line each, for example **Toolbox: The Deadmines (17–26), 3/5**. Groups whose range is within 2 levels of your character's level come first; the rest are listed in grey. A group drops off the list when its organizer ends it, or a few minutes after their add-on was last heard from.

Click a group to see its slots in place of the dungeon picker: who's in each one, with **(coming)** beside anyone the organizer is still waiting on, and **open** for the rest. An open slot you could fill has a **Fill Slot** button: your character's level must fit the dungeon, its class must play the role, and the role must be on in its [role preferences](#role-preferences). If the character you're on can't, the button reads **Fill as Alt** and opens a list of your alts that can, each with its level. Pick one to offer it. **Back** returns to the dungeon picker.

**Fill Slot** doesn't put you in the group. It sends the organizer a prompt, **Hammer offers to fill your Healer slot**, with **Accept** and **Decline**. Under the slots you see where your offer stands, and the add-on tells you in chat when the organizer answers. An offer the organizer accepts works like an accepted request: the slot is held for you until they invite you. An offer goes unanswered after about 2 minutes, and closes if that role fills in the meantime.

### In someone else's group

Once you're in the party of a guildmate who is forming a group with the add-on, the Group Finder shows you their group, as it fills, instead of the dungeon picker. You can't invite or request anyone from it, but two things are yours to change:

- **Your role:** the **Tank**, **Healer** and **DPS** buttons ask the organizer to move you to another open role your class can play. The organizer's add-on moves you as soon as it hears.
- **Join as an alt:** one button for each of your alts that could come instead, for example **DPS — Bolt (23)**. Choosing one tells the organizer you're coming on that alt: it takes your slot, and their window shows **Waiting for Bolt to log in**, then **Invite** once Bolt is online. Log over to the alt and wait for the invite.

You can also just log over to an alt without telling the organizer, as before.

### Ask in guild

To reach guildmates without the add-on, press **Ask in guild** (shown while any role is open). Your chat box opens on guild chat with a ready-made line already typed, for example **LF healer and 2 DPS for The Deadmines (17–26), whisper me!**, naming the open roles, the dungeon and its level range. Change it however you like and press Enter to send it, or Escape to send nothing. The add-on never posts it for you.

### Who is around

Each time the Group Finder tab comes into view, your add-on asks the guild who else runs it. Every guildmate online with the add-on answers within a few seconds, and the bottom of the tab lists them, for example **Add-on users online: Hammer, Wrench (unavailable)**. Guildmates without the add-on don't answer, so they aren't listed here. People log on and off while you have it open: press **Refresh** at the bottom right to ask again and update everything.

### Nearby

The right side of the window always ends with **Nearby in <zone>**: the guildmates online in the same zone as you, at any level, one line per player under their alias (or main), with the characters they have there and their levels, for example **Thunderer — Bolt 22**. It's there before you pick a dungeon too, so you can see who you might quest with. It's worked out again each time the window opens or refreshes.

### Do Not Disturb

Turn on **Do Not Disturb** when you don't want group requests. It's in four places that always agree: the check box at the bottom of the Group Finder, the same check box at the bottom of [My Profile](#my-profile), **Do Not Disturb** under **Group Finder** in the settings, and `/agf dnd`. It applies to every character on your account. While it's on, your add-on tells organizers you're unavailable.

You're also unavailable automatically while you're in a group or inside an instance, with nothing to turn on.

### Role preferences

Each character has its own role preferences: the roles you're willing to play on it. They start as every role its class can fill. To turn one off (say, a paladin you never heal on), log into that character and untick it on the [My Profile](#my-profile) tab. Only the roles that character's class can fill are listed. The player panel shows each character's role preferences next to it, as **Roles: Tank, DPS**.

Your role preferences reach the whole guild through [guild sync](#guild-sync), even while you're on another character or offline. Only the character itself can set them, not officers or anyone else. If your add-on sees a change in your character's name that you never made, it sends your real preferences back out to correct it, and warns you who passed it on.

### Group history

Your add-on remembers, on your computer only, each party you've been in with guildmates: any party, not just ones from the Group Finder. It records when, which guild characters, and the dungeon when it knows it (the one you picked in the Group Finder, or the instance you're in). Guildmates joining later count as the same party, and so does reloading while in it. Your own alts never count. The history is never sent to anyone.

A guildmate's player panel then shows **Grouped together 3 times, last on 2026-10-12**, counted across all their characters. Players you've never grouped with show nothing.

## Guild map

Guildmates running the add-on share where they are, so you can see where the guild is playing and find people to meet up with.

- **Zone map and minimap**: each guildmate in that zone is a dot in their class color at their exact position. Dots that would cover each other are moved apart by a dot's width. On the minimap you see the guildmates in your own zone.
- **Continent map**: each zone with guildmates has one marker, placed where they are in that zone. One guildmate shows as a dot in their class color; 2 or more show as a count. Point at a zone with a count to list its guildmates at the right of the map.
- **World map**: one marker per continent, over its land (Kalimdor and the Eastern Kingdoms have fixed spots). Point at a continent with a count to list its guildmates under its name.
- Hover a single guildmate's dot to see their name, alias or main (the same as their [chat tag](#chat-tags)) and level, as `Name (Main) (70)`. A count has no tooltip of its own: its area's list shows everyone there.
- Guildmates without the add-on, and those whose position hasn't arrived yet, still count on the continent and world maps at zone level, using the zone the guild roster shows. On their zone's own map each gets a dot at the zone's center, since the roster names only the zone; its tooltip ends with **(exact location unknown)**. They never get a dot on the minimap.
- While you're in a party, guildmates outside it are slightly dimmed on every map and the minimap, so your party members stand out. A marker with nobody from your party is dimmed as a whole.
- Your own characters never show.

Guildmates in your zone move every 10 seconds or so; everyone else updates about every 2 minutes, and promptly after a zone change. Same-zone updates go by whisper to at most the 10 guildmates heard from most recently. If whispers don't work, the add-on falls back to the guild-wide update alone.

A dot disappears when the guildmate:

- enters a dungeon, raid, battleground or arena (they come back when they leave),
- turns sharing off,
- hasn't sent an update for 5 minutes, or
- shows as offline, or gone from the guild, in the guild roster.

Nothing is sent during combat, a boss encounter or a keystone run. Location messages from outside the guild, or from add-on versions yours doesn't understand, are ignored.

Two settings, in the window's **Settings** tab and the **Guild Map** page of the AddOns options, apply to every character on this game install:

- **Share my location with the guild** (on by default). Turning it off removes your dot from everyone's maps at once, and nothing more is sent until you turn it back on.
- **Show guildmates on the map and minimap** (on by default). Turning it off clears every guildmate dot and marker from your maps.

## My Profile

**My Profile** is a tab of the add-on's window, right below **Roster**: one place for everything about your own player. Click its tab, or type `/agf profile` to open the window straight on it (typing it again while it's showing closes the window). Each time the tab comes into view, it reads everything again.

It shows the player of the character you're logged in on: its alias and main at the top, for example **TheTool (Toolbox)**, then the main and each alt still in the guild, in its class color with its level. The character you're logged in on is marked **logged in**.

### Alias, main and alts

Below the heading are the same edits as the roster's right-click menu, for your own player:

- **Alias**: type an alias (up to 48 characters) and press Enter to set it, or empty the box to clear it.
- **Make main** on an alt makes it your player's main.
- **Remove** on an alt splits it off as a player of its own (**Split off as own player**).
- **Declare as my main** says your main is your main on purpose, even if you have no alts. Your main then shows as **declared main**, here and in the roster.
- **Add alt…** opens a search of the guild's other characters. Pick one and press **Add** to link it as your alt. Once your player has alts (or an alias), it lists only characters on their own: another player's characters can't be taken from them. If the character you're on is still on its own, it also lists other players' characters. Pick one and press **Join** to make the character you're on an alt of that player.

These follow the same rules as the roster. An officer's edits are official at once and reach the whole guild. A member's apply in their own roster at once and are sent to officers as [suggestions](#suggestions). The page shows each change straight away.

Below your characters, **Your other characters on this computer** lists the characters you've logged in on with this game install, in this guild, that aren't linked to your player yet. Each has **Add as alt**, which links it to your player, and **Dismiss**, which stops offering it on this computer for good. Nothing is ever linked by itself, so on a shared or family computer someone else's characters never end up as yours. The list of characters you've logged in on stays on your computer and is never sent to anyone.

### About me

Below the alias are your **Discord** username (up to 32 characters), **Location** (up to 40, for example "Ohio, evenings") and a **Bio** (up to 500, in a taller box that wraps onto several lines). Each box shows how many characters you've used. Type in one and press Enter (or click elsewhere) to save it; Escape puts back what was saved. Empty a box and save to stop sharing it.

These belong to your player, not to one character: whichever of your characters you're on, you see and edit the same values, and the newest edit wins. They're yours alone. They're saved and sent to the guild at once, with no officer approving them, and only your own characters can change them; officers can't edit or clear them. If someone's add-on passes on a change in your name that you never made, yours sends your real values back out, and you're warned who passed it on, as for role preferences. Guildmates see them under **About** in your player panel.

### Characters and roles

Under each character are its [role preferences](#role-preferences). The character you're logged in on has a check box for each role its class can fill. Ticking one changes it, and the guild hears about it through [guild sync](#guild-sync). Your other characters' roles are shown but can't be changed here: log in on that character to change them.

Along the bottom is the **Do Not Disturb** check box, the same setting as in the Group Finder, the settings and `/agf dnd` (see [Do Not Disturb](#do-not-disturb)).

On a character that isn't in a guild, My Profile just says it needs one. Right after joining, before the add-on has scanned the roster, it asks you to try again after the next scan.

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

The add-on uses LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0, LibSharedMedia-3.0, the Details! Framework, AceSerializer-3.0, AceComm-3.0 (which brings ChatThrottleLib), and HereBeDragons-2.0 with HereBeDragons-Pins-2.0 (for the [guild map](#guild-map)). They are not committed. [`tools/libraries.txt`](tools/libraries.txt) pins each one to a tag, and both release packages (`.pkgmeta` externals) and development checkouts use those pins. To fetch them into the git-ignored `Libs/` folder, run this in PowerShell (Windows PowerShell or `pwsh`):

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
