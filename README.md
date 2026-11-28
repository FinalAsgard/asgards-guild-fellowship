# Asgard's Guild Fellowship

A World of Warcraft add-on for the guild's member database and Fellowship roster: who each player is, which characters are their mains and alts, and the alias they choose to be called. It supports WoW Forever and WoW Retail from one source tree.

The add-on groups the guild's characters into **players**. Each player has one main, any number of alts, and an optional alias. The grouping is seeded from public guild notes, and from then on it's kept in a local database. You change it by hand, and officers' edits reach it through [guild sync](#guild-sync).

## Installing

Install **Asgard's Guild Fellowship** from CurseForge, for example with the CurseForge app. One download works on both supported clients, WoW Forever and WoW Retail (see [Supported clients](#supported-clients)). To install by hand, unzip the release into your client's `Interface\AddOns` folder so that you have `Interface\AddOns\AsgardsGuildFellowship`.

## Commands

| Command | What it does |
|---|---|
| `/agf` or `/agf roster` | Opens the add-on's window on the **Guild Roster**, or closes it. |
| `/agf rescan` | Scans the guild's notes right away. |
| `/agf recruit` | Opens the old window on the **Recruitment** tab. |
| `/agf greet` | Opens the add-on's new window on **Greetings**, where you edit your Guild Greet greetings and settings (see [Editing greetings](#editing-greetings)). |
| `/agf options` | Opens the old window on the **Settings** tab. |
| `/agf minimap` | Hides the minimap button, or brings it back. |
| `/agf tags` | Turns chat tags off, or back on. |
| `/agf lfg` | Shows the LFG button if it's hidden, and opens the [Guild LFG Board](#guild-lfg-board). |
| `/agf profile` | Opens the old window on the **My Profile** tab (see [My Profile](#my-profile)), or closes it. |
| `/agf dnd` | Turns [Do Not Disturb](#do-not-disturb) on, or back off. |
| `/agf advertise` | Posts your guild ad to General where you are, now. `/agf advertise trade` posts it to Trade. Works in a macro. Won't post again before your timer allows (see [Guild Recruit](#channels-and-timing)). |
| `/agf channels` | Shows the chat channels Guild Recruit sees where you are: each channel the game lists, whether it's disabled here, and which ones it would post to for General and Trade. |
| `/agf mail` | Opens [Guild Mail](#guild-mail), to mail the guild ranks you pick (officers only). |
| `/agf sync` | Shows guild sync status: whether it's running or paused, when you last synced, and how many of your suggestions are waiting for an officer. |
| `/agf resync <name>` | Replaces your roster data (main and alt links, aliases, declared mains, and Discord, location and bio) with an online officer's copy, whatever the edit times. For when your roster went wrong and sync won't correct it. See [Resync](#resync). |
| `/agf setdate join\|rank <character> <YYYY-MM-DD>` | Sets a character's join date, or the date it reached its current rank, when you know better than the add-on (officers only; see [Dates behind the checks](#dates-behind-the-checks)). |
| `/agf perf` | Shows the add-on's memory use, its CPU use (when the game's script profiling is on, or how to turn it on), and counts since login of its costly work: roster reads, roster-update refreshes, scans, map redraws, chat tags and greet checks (anyone). |
| `/agf probe` | Shows when the roster last had a full scan, and how many guild notes the latest scan picked up as changed (anyone). |
| `/agf probe forgeries` | Lists the last 10 guild sync edits your add-on caught as forged in your name: when, who passed each on, what it changed, its stamp, and what your own record of your edits held for it (anyone). |
| `/agf probe player <name or alias>` | Shows how your add-on holds a player: its alias, who set it and when, and through which character; each character's link and Discord name with who set them and when; and the player's last 10 logged changes (anyone). |
| `/agf probe log`, `/agf probe officer`, `/agf probe ready` | Reports what the game gives the add-on: the guild event log, the officer channel, or whether the **Ready** and **Promote to match** flags reach the game's guild roster (officers only). |
| `/agf probe greet` | Shows your greet weight, how many guildmates with the add-on count as online, and how much longer your greet prompts wait because of it. |
| `/agf probe lfg` | Shows the Guild LFG Board as your add-on sees it: your zone's levels and where they came from, how many questing zones the game's map tree gave, your listing and whether guildmates' add-ons can read it as sent, the listings on your board by tab, and since login how many board messages went out, how many came in and from whom, and how many were ignored and why (anyone). |
| `/agf help` | Lists the commands, with the version, client, and library status. |

## The add-on's window

The add-on has two windows while its pages move over.

**The window**, which `/agf`, the minimap button, the add-on compartment, the guild window's **Guild Fellowship** button and the AddOns options' **Open window** open on the **Guild Roster**. Its sidebar has:

- **Roster**: the guild's players, mains and alts (see [Using the roster](#using-the-roster)).
- **Friends** (see [Friends](#friends)), **LFG** (the [Guild LFG Board](#guild-lfg-board)) and **Greetings** (see [Editing greetings](#editing-greetings)).
- **Rank management** (officers only, under **Officer**): who's due a promotion, every player's standing, and each rank's requirements (see [Promotions](#promotions)). Its sidebar button counts the players due.
- **Settings** at the bottom.

`/agf` closes the window when it's showing the Roster, and switches to the Roster from any other page. It remembers where you left it.

**The old window**, with picture tabs down its right edge. Hover a tab to see its name, and click it to show its page. `/agf profile`, `/agf recruit` and `/agf options` open it on their tabs:

- **My Profile**: your own player, its characters and their role preferences, and Do Not Disturb (see [My Profile](#my-profile)).
- **Recruitment**: your [Guild Recruit](#guild-recruit) settings, and for officers the guild's settings and the **Recruiters** leaderboard (see [Ad counts](#ad-counts)).
- **Recent Guild Advertisements**: where the guild advertised lately, who posted, and how long ago (see [Ad counts](#ad-counts)).
- **Guild Log** (officers only): the guild's long-term record of joins, invites, leaves, kicks, promotions and demotions (see [Guild Log](#guild-log)).
- **Settings**: everything else (General, Chat Tags, Guild Map, and Do Not Disturb), the version you're running, and for officers the guild note **Conflicts** button (see [Guild notes are the master copy](#guild-notes-are-the-master-copy)).

Every page scrolls when it's taller than the window. Escape or the close button closes it. It remembers its size and position, and you can resize it down to a minimum.

## Settings

The settings are in two places that always agree: the window's tabs, and **Esc → Options → AddOns → Asgard's Guild Fellowship**. In the AddOns options, the add-on's own page has an **Open window** button and the version, and each feature has a sub-page of its own under it:

- **General**: show or hide the minimap button, **Auto-list my parties** and **Show my party on the guild's board** (see [Listing your party](#listing-your-party)), and the version you're running.
- **Chat Tags**: turn chat tags on or off, and choose the colors of the alias tag and the main's-name tag (see [Chat tags](#chat-tags)).
- **Do Not Disturb**: the same switch as on My Profile and `/agf dnd` (see [Do Not Disturb](#do-not-disturb)).
- **Guild Map**: **Share my location with the guild** and **Show guildmates on the map and minimap**, both on unless you turn them off (see [Guild map](#guild-map)).
- **Guild Greet**: first, **Show greet prompts** turns Guild Greet on or off on every character; under **Prompts**, turn it off on just the character you're playing, choose whether to greet during dungeons and raids, turn **Highlight group friends** on or off, choose **Greet prompts for: Everyone / Grouped with / My Friends** (see [Group friends](#group-friends)), and press **Move greeting pop-ups** to move the prompts; under **Which arrivals to prompt for**, turn each category's prompts on or off, and **Use friend greetings for starred friends**; under **Timing**, set the welcome-back minutes; under **Close my prompt after**, set how many greetings close your prompt for a login or welcome back, and how many welcomes close it for someone who just joined. Last comes a tinted **Officer settings (officer only)** area with the guild's **Slow mode** slider, from 0 (off, the default) to 15 minutes between each greeter's greetings. It applies to everyone in the guild: officers change it, and the newest officer change reaches every add-on user. Everyone else sees the guild's value greyed out, with a line saying only officers can change it. In the AddOns options it also has an **Edit Greetings** button that opens the new window on Greetings, where the same settings are (see [Editing greetings](#editing-greetings)).
- **Recruitment**: how many guild ads you've posted (all your characters together, and in the last 30 days), then turn [Guild Recruit](#guild-recruit) prompts on or off on the character you're playing, write your own ad, choose whether you also post the officers' guild ad (hover the info icon beside it to read the guild ad), and set your own timers (sliders) for how long General and Trade go without a guild ad before you're asked. On a character that can't invite to the guild these are greyed out, with a line saying why. Officers also get the guild ad, the guild's floor under everyone's timers for General and for Trade, and a pause for the whole guild, under their own **Officer settings** heading because they apply to everyone in the guild. Regular members don't see the officer settings.

A change made in the window, the AddOns options or a slash command shows up in the other places at once. Settings are saved for every character on this game install. The development build's options are labeled "(Dev)".

## Using the roster

### Opening it

The roster is the **Guild Roster**, the **Roster** page of [the add-on's window](#the-add-ons-window).

- `/agf` (or `/agf roster`) opens the window on the Guild Roster. If it's already showing it, it closes the window; on another page, it switches to the Roster. The development build uses `/agfdev`.
- The minimap button does the same. For officers, its tooltip shows how many conflicts are waiting. Drag it to move it; its position is saved. `/agf minimap` hides it, and running it again brings it back.
- On Retail, the add-on compartment has an entry for it as well.
- The guild window gets a **Guild Fellowship** button left of **Invite Member**. If the add-on can't find that button, it skips this one quietly.
- `/agf help` lists the commands with the version, client, and library status.

Opening the window never scans the guild, so it's always quick.

The page has a column of player cards on the left and the selected player's [player panel](#the-player-panel) on the right. Across the top it says how many players there are and how many are online, and when you last synced, with **Rescan** on the right. Officers also get three tabs: **Members** (the cards), **Departed** (see [Mains, alts, and departures](#mains-alts-and-departures)) and **Review** (members' suggestions, see [Suggestions](#suggestions)).

### Guild size

Hover the player and online counts at the top of the Guild Roster for the guild's size, whatever the search and filters: how many players there are, and how many of them are **known** or **unlinked**, how many were active (online, or last online) within 7, 30 and 90 days, who is online now, and how many players have an alias or a declared main. Departed characters never count.

- A **known** player has two or more linked characters, an alias, or a declared main.
- An **unlinked** character stands alone, with no link, alias or declared main. It counts as a player of its own until it's linked, though it may be someone's alt. Linking it moves it from players to alts.

### The guild note convention

Two markers in a character's **public** note seed the database:

- `Main: Toolbox` or the shorter `>Toolbox` means "this character is an alt of Toolbox".
- `Main: TheTool` or `>TheTool`, naming an alias instead, means "this character is an alt of the player who goes by TheTool", whoever their main is. The alt stays linked when that player changes main, so its note never has to be rewritten.
- `Alias: TheTool` or the shorter `@TheTool` means "this player goes by TheTool".
- `^` at the very start of the note (for example `^ @TheTool raid lead`) means "this is my main, on purpose": a **declared main**, even with no alts. A main marker naming the character itself (`>Toolbox` on Toolbox's own note) says the same at more length. On a character the roster has as someone's alt, either one splits it off as a main of its own, unless that link was set in the add-on (then it goes to the officers' conflict queue). A `^` anywhere else in the note is just text.

A marker can sit anywhere in the note (for example `Tank, Main: Toolbox, Alias: TheTool`, `Tank >Toolbox` or `@TheTool raid lead`), and both kinds can appear in one note. Only the first main marker and the first alias marker count. The `Main:` and `Alias:` labels can be any case (`main:` works too), the space after the colon is optional, and a label only counts as a word of its own (`Domain:` isn't a main marker). Matching ignores case.

- On **WoW Forever**, names have a first and last name: `Main: Tool Box` and `>Tool Box` work. So do `Main: Tool` and `>Tool`, as long as only one guild character has the first name Tool.
- On **Retail**, `Main: Toolbox` and `>Toolbox` use the single character name. A realm suffix is optional.

An alias from a note is one word: letters (accented ones too), digits, `_`, `'`, and `-`. Longer aliases can be set in the window, up to 48 characters.

A main marker's word is checked against aliases first, then against character names. So when a word is both someone's alias and a character's name, the note links to the player with that alias. Only one-word aliases can be named, upper and lower case don't matter, and on Forever `>Tool` matches the alias Tool before it tries a first name. A main's `@TheTool` and its alts' `>TheTool` link up in the same scan. A main marker naming the player's own alias (`>TheTool` on one of TheTool's characters) changes nothing.

If two players share the alias a note names, or nobody has that alias yet, the add-on doesn't guess: the note changes nothing for now. When an alias is set, changed or cleared (from a note, by hand, or through [guild sync](#guild-sync)), those notes are read again on the next scan, so the alt links itself as soon as the alias exists.

The add-on never writes to guild notes.

### Scanning

- Every login (and `/reload`) scans the roster, so ranks, notes and departures that changed while you were away show at once. Only notes that changed are read again, so it's quick. It says nothing in chat unless it found something.
- New members, changed guild notes, and rank or level changes (including promotions made in the game's own guild window) are picked up automatically when the guild roster updates. While you're online the add-on asks the game for a fresh roster every 15 minutes, so a note an officer edits reaches you within 15 minutes, without a relog. `/agf probe` shows when the last full scan ran and how many notes the latest scan changed.
- **Rescan** at the top of the Guild Roster, or `/agf rescan`, scans right away.

Scans run a little at a time, so even a large guild doesn't cause a hitch. A scan that found something says so in chat, and `/agf probe` shows when the last one ran.

### Guild notes are the master copy

- On the first scan, note markers are applied directly to any character the database doesn't know about.
- After that, a note that changes wins over what the notes or the roster set before: a character moves to the main its note now names, a player takes the alias its notes now give it, and an alt whose note now names itself as main becomes a main of its own. Nothing goes to the conflict queue for these. The player the character left records it in their history ("moved by a guild note").
- The only conflicts are changes submitted through the add-on that disagree with the guild notes: a member's suggestion (see [Suggestions](#suggestions)), and a note that disagrees with a link or alias set by hand or through [guild sync](#guild-sync). Those keep what was submitted until an officer decides.
- A note naming a character that doesn't exist, matching more than one, or looping back on itself changes nothing and is not a conflict. Neither do notes read in the same scan that give one player different aliases (a note changed later can still rename the player), or two mains whose notes name each other's players. A note naming someone not in the guild yet is read again when someone new joins, or when the guild's aliases change.
- **Conflicts (N)** at the bottom of the old window's **Settings** tab opens the queue. Only officers have it: members see no Conflicts button or window, no count in the minimap tooltip, and no conflicts in the scan report in chat. It appears or disappears without a reload when someone is promoted to or demoted from an officer rank. Members' changes are listed under **Changes to Player**, one line per player. Notes that disagree with a submitted link or alias are listed below them under **Note conflicts**: each shows the character, then one wrapped column with the note, what it suggests and what the database says. Accept or reject each one, or all at once.
- A rejected note conflict stays away until that note changes again.
- Conflicts an earlier version queued that don't fit these rules (unknown or ambiguous mains, loops, competing aliases, new acting mains to confirm) are cleared once, and the notes behind them are read again by the next scan.
- Officer data from [guild sync](#guild-sync) beats an unchanged guild note. On a new install, notes fill in the roster first, and officer edits replace them where the two disagree. After an officer edit arrives, the next scan checks the notes it affects again. A note that disagrees goes to the conflict queue, and a pending conflict the edit already settled disappears.

### Out-of-date guild notes

Guild notes are how members without the add-on see who's whose alt, and they drift whenever mains, alts or aliases change. Officers see which notes are out of date right in the game's own guild roster (the Communities guild roster, on both clients). Members who aren't officers see nothing new.

- Each member whose public note is out of date gets a small yellow marker at the right of their row.
- Select that member, and a small panel right under the game's member details, as wide as them, shows **Should be: …** with the suggested note, then what's wrong with it: **No main marker**, **Main marker names the wrong player**, **Main marker shouldn't be there**, **Alias missing**, **Wrong alias**, or **Main marker can't be read**.
- Retype the suggestion in the game's note editor. The add-on never writes guild notes.

What a note should say:

- An alt points at its own player: `>Alias` and `>Main` both count as correct. A suggestion uses `>Alias` when the player has a one-word alias nobody else in the guild has, and otherwise the shortest form of the main's name that reads back as the right character (a unique first name on Forever).
- A main carries `@Alias` when its player has a one-word alias. A [declared main](#organizing-by-hand)'s note also starts with `^` (a main marker naming itself counts as correct too). On an alt, `^` or a marker naming itself is flagged as naming the wrong player.
- A character on its own, and not declared, has no main marker. An old marker left from before it was split off is flagged.

`Main:` and `Alias:` labels that read correctly count as correct: style alone is never a problem. The suggestion puts the correct markers first and keeps the rest of the note's text after them. Public notes hold 31 characters. When the suggestion would be longer, it shows just the markers, with **Too long for a public note: the other text has to be trimmed.**

**Ignore** hides a mismatch you've chosen to leave alone. It comes back when the note or the add-on's record for that character changes. The list is worked out again after every scan, sync and change in the roster. Departed characters are skipped.

### Following the game's guild roster

While the Guild Roster is open, selecting a member in the game's guild roster selects their player there too, when the add-on knows them. With the window closed, nothing opens.

### Mains, alts, and departures

- A player always leads with a character who is in the guild. If their main leaves, or a note names a main outside the guild, an in-guild alt becomes the acting main: the highest level, then the most recently online. The player's history records it, and you can pick another main with **Make this the main**.
- Characters who leave are kept and marked departed. They're left off the player cards, and officers list them on the Guild Roster's **Departed** tab: each character, its player, and when it left. A returning character goes back to their old player automatically.
- **Purge** on the Departed tab removes one departed character. **Purge all departed** removes them all, after asking.

### Organizing by hand

A player card marks a **declared main** (a player who said "this is my main" on purpose), so confirmed players stand apart from characters nobody has organized yet. Players declare their main on [My Profile](#my-profile), or by starting the character's note with `^` (see [The guild note convention](#the-guild-note-convention)). Like the other organizing changes, an officer's declaration is official at once and a member's goes to officers as a [suggestion](#suggestions).

Right-click a player card for **Set alias…** and **View player…**. Right-click a character card on the player panel's **Characters** tab for **Link as alt of…** (makes it an alt of another player), **Make this the main**, **Set alias…**, **Split off as own player** (takes it out of its player into one of its own), and **View player…**. The panel's **⋯** button has **Whisper** and **Invite** (for a character online), **Set alias…**, **Set Discord…** and **Merge into player…**. **Link as alt of…** and **Merge into player…** swap the panel for a player picker with a search box; **Set alias…** and **Set Discord…** ask for the text in a small box. **Set Discord…** sets the player's Discord name: an officer's edit is saved at once, and a member's becomes a suggestion for an officer to approve.

Members can change only their own player: on anyone else's player, the menus offer only what they may do (**View player…**, **Whisper**, **Invite**). A member can link a character only if the add-on knows it's theirs (it's on their player, or they've logged in on it with this install), and only to a player the add-on knows is theirs: **Link as alt of…** and My Profile's **Add alt** list nobody else. Officers can change anyone's. **Merge into player…** links the player's main as an alt of another player, the same as **Link as alt of…** on the main. A main that still has alts can't be moved: move its alts or split them off first.

Changes show up right away and are recorded as manual. An officer's changes then reach the rest of the guild through [guild sync](#guild-sync), and a member's are sent to officers as [suggestions](#suggestions). Data is saved per guild and shared by every character on this game install.

### The player panel

The player panel, on the Guild Roster and the [Friends](#friends) page, shows the player's alias (else their main's name) with their main's level, class and rank and where they are, the **Friend** star, and four tiles: **Discord**, **Grouped** (how often you grouped with them, 0 times included), **Last grouped** and **Joined guild** (officers only). Its tabs:

- **Characters**: their characters in the guild, main first, each with its role preferences.
- **Bio**: their **Location** and **Bio** (see [About me](#about-me)), each "Not set" until it is. On your own player, or anyone's if you're an officer, each has an **Edit** button. Empty either and save to clear it. Your own player's Location and Bio go to the guild at once with no officer approval, and an officer's edit of anyone's does too; the Bio's count is in bytes, since an accented letter takes two.
- **Grouped**: your parties together, newest first, with **Show more**.
- **Log**: the player's ad count (see [Ad counts](#ad-counts)), when you last grouped, and each character's join and rank dates (officers only), then **Changes** (each change to the player's alias, main, characters, Discord, location or bio, newest first, with when, who made it, and whether it was made here or arrived through guild sync), then **History**: characters that left the player (left the guild, split off, or moved to another player).
- **Rank** (officers on anyone, members on their own player only): see [The player panel's Rank tab](#the-player-panels-rank-tab).

### Finding people

- The search box matches aliases, character names and Discord usernames. A card found by an alt's name says so ("matches Bolt Smith").
- **Sort** orders the cards by **Name**, **Last online**, **Rank** (with each player's rank after their name) or **Grouped with** (how often you grouped).
- **Rank** shows only players at one rank.
- **Online only** hides players with no character online.
- Cards for players online come first. A card stays where it is when someone logs on or off, until you sort, filter or search again.

## Guild sync

When an officer changes which characters belong together, or what a player goes by, the change reaches everyone in the guild who runs the add-on and is online. This covers **Link as alt of…**, **Merge into player…**, **Make this the main**, **Split off as own player**, and **Set alias…**, including clearing an alias. Officers' edits update your roster and chat tags without a rescan.

- An officer is anyone whose guild rank can view officer notes. The guild master always counts. Nothing needs to be set up: promoting or demoting someone changes what their edits do.
- When two officers change the same character or the same alias, the most recent edit wins everywhere.
- A member's own edits apply in their roster right away and are sent to officers as suggestions (see [Suggestions](#suggestions)). Only officers' edits change everyone's roster directly.
- Edits made before sync existed: they become official and are sent to the guild once you log in on an officer character with this version. Until then, and for members, they stay in your own roster only.
- Only main and alt links, aliases, each character's [role preferences](#role-preferences), and each player's [Discord, location and bio](#about-me) are shared. Role preferences and About me are set by the player's own characters and reach the guild at once with no approval. The exception is officers: an officer can also set or clear anyone's Discord name with **Set Discord…**, and their location and bio from the player panel's **Bio** tab. A member's **Set Discord…** on another of their own characters becomes a suggestion for an officer to approve. Officers' add-ons ignore a member's alias or Discord suggestion about a player who isn't theirs. Guildmates who were offline get them through the same catch-up as everything else. Departures, purges, history (including your [group history](#group-history)), conflicts, and settings stay on your computer.
- Sync messages go out at the game's lowest add-on priority, so they never hold up chat or other add-ons.
- The top of the Guild Roster shows when you last synced, meaning the last time your add-on compared or exchanged officers' data with another add-on user. `/agf sync` shows the same, plus whether sync is paused and how many of your suggestions are waiting.
- Sync never gets in the way of play. It sends and processes nothing while you're in combat, or on Retail during a boss encounter or a keystone run, and picks up where it left off once that's over. Like scans, it works on data a little at a time, so even a large guild's full sync doesn't cause a hitch, and your roster redraws once per batch rather than once per change.

### Resync

Sync keeps the most recently edited version of everything, so if your copy of a player went wrong with a newer edit time than the officers' copy, sync keeps your wrong copy. `/agf resync <name>` replaces your copy with an officer's instead:

- Name an officer who's online: the name of the character they're playing, or their alias. Their add-on sends you its whole roster copy. The game only sends a little add-on data per second, so a big guild's roster takes a minute or two; your chat shows how far along it is and roughly how long is left, then how many players changed once it's applied.
- The officer sees a line asking them to stay online until it's done, and another when it's finished. If they log off (or stop sending) partway, you're told after 90 seconds without progress, and nothing changes; run it again later. If their add-on doesn't answer within 30 seconds (it may be an older version), you're told that too.
- It replaces main and alt links, aliases, declared mains, and Discord, location and bio, keeping the officer's edit times. Your own characters' Discord, location and bio, role preferences, membership dates, history and settings are left alone. Characters your add-on hasn't seen yet are skipped.
- Only an officer's copy is accepted, and only the one you asked for. Each player's **Log → Changes** shows what changed "(resync)".
- The officer's add-on answers each guildmate at most once a minute. You can only resync from one officer at a time.

### Suggestions

Members know their own alts best, so a member's edits become suggestions for the officers:

- When you're not an officer, **Link as alt of…**, **Merge into player…**, **Make this the main**, **Split off as own player**, and **Set alias…** still change your roster at once. Each change is also kept as a suggestion. They work only on your own player (the character you're logged in on and the characters linked to it), and you can link only characters the add-on knows are yours (on your player, or logged in on with this install). Officers' add-ons ignore a member's suggestion about a player who isn't theirs, one that would bring over a character the officer's roster has on another organized player (with an alias, other characters, or declared as a main), and one that would take the member's own characters to another player. A character nobody organized that the member is playing may still ask to join a main, for the officer to review. An approval is checked again, so a suggestion that's no longer the member's to make is refused.
- Suggestions go to the guild as soon as an officer is online. If none is, they wait, and are sent when an officer logs in.
- Officers find them on the Guild Roster's **Review** tab, with **Approve**, **Deny**, **Approve all** and **Deny all**, and **Review** for a change to a main or its alts, which shows the player before and after. They're also in the old window's **Conflicts** window under **Changes to Player**, above **Note conflicts**: one line per player with changes waiting, with how many there are, **Suggested by** (the character that suggested them, with its player's alias or main when that differs, for example "Bolt (Hammer)") and a **Review** button. Suggestions from members on older versions of the add-on are grouped the same way. The Conflicts button and the minimap tooltip count each player's changes once, plus each note conflict.
- **Review** opens a panel beside the window. Its header says who suggested the changes. For every player the changes touch (a member linking their character under someone else's main touches both players), it shows the player as they are now (**Before**) and as they'd be with every change (**Suggested**): main (and whether it's declared), alias, Discord, and each alt on a line of its own. Lines that change are colored: the old value red, the new one green. The live guild note of each character involved is shown below for context. Then each change has its own line in plain words, for example "Bolt: Alt of Toolbox → Alt of Hammer", with **Approve** and **Deny**. **Approve all** and **Deny all** decide the whole player at once, and Accept all and Reject all at the bottom of the Conflicts window still decide everything.
- The first officer to decide settles the suggestion for every officer, and it disappears from the other officers' queues. Accepting makes it an official edit under that officer's name, which reaches everyone.
- Denying puts your roster back the way the officers have it, so you stay on the same data as everyone else. If no officer ever set that character or alias, it goes back to what the guild notes and the roster say.
- Until then, your edit stays in your roster unless a newer officer edit about the same character or alias arrives.
- Your suggestions that are still waiting are listed on [My Profile](#my-profile) under **Waiting for an officer** (members have no Conflicts window), and they leave the list once an officer decides them. Suggestions are only sent while you're online, so if you log off before an officer decides, yours are sent again the next time an officer is online.
- All your waiting changes, made from any of your characters, from the roster or from My Profile, form one request for your player. [My Profile](#my-profile) lists them under **Waiting for an officer** in plain words, for example "Wrench as an alt of Hammer" or "Alias: Hammers".
- Changing the same thing again replaces your earlier change in the request. Changing it back to how the officers have it drops it from the request, and from officers' queues.
- **Undo** beside a waiting change puts your roster back the way the officers have it and takes the change back from officers' queues (officers who are offline are told when they next log in). An officer still on an older version of the add-on may keep seeing it until they decide it.
- When an officer decides one of your changes, chat tells you: "An officer approved your change: …" or "An officer denied your change: …". A denial rolls back only that change; the rest of your request keeps waiting.

### Catching up when you log in

You don't need to be online at the same time as an officer. Officers' edits also reach you through other add-on users:

- About 30 to 60 seconds after you log in, your add-on asks the guild whether your copy of officers' data matches theirs. It sends a short summary, never the data itself.
- If someone's copy is the same, nothing else is sent. If it differs, one add-on user who has the officers' edits sends back only the part that differs. That can be any member, but an online officer answers first. If you hold officer edits they're missing, yours go back the other way.

### How sync protects your data

Any add-on user can pass officers' edits on, so the add-on checks what it receives:

- An edit is only accepted when the officer it names holds an officer rank on the current roster. A member can't make their own edits official by passing them on.
- An edit dated more than a few minutes in the future is refused, so a faked date can't make an edit win over every real one.
- When an officer is online, your data is checked against theirs directly. Officers answer catch-up requests before members do, and the game guarantees who sent each message, so differences come from the officer's own copy.
- Each officer's add-on keeps a ledger of the edits that officer made. If someone passes on an edit in an officer's name that overrides one the officer did make, that officer's add-on catches it as soon as it sees it. That happens either right away, or when the officer next logs in and checks the guild's data. The add-on refuses the edit, sends the officer's own data to the whole guild to replace it, and logs which character passed it on. It also warns the officer in chat.
- A forged edit can only last until the officer it names is online again. Edits dated before an officer's add-on started its ledger, including ones from before this version, are trusted. So is an edit in an officer's name about something that officer's add-on has no edit of theirs for (guildmates' rosters can name a player by another main, or hold a guild log date the officer's add-on never kept): it overrides nothing of theirs, and is applied like any other officer's edit.
- The ledger is kept in that computer's saved data. If you're an officer who plays on two computers, an edit you made on one can look forged to the other, which then puts back its own data. Make officer edits on one computer.

## Chat tags

In guild chat, officer chat, party chat, and guild achievement announcements, a tag after the speaker's name shows who the player is (in party chat, only for guildmates: anyone from outside the guild gets no tag):

- If the player has an alias, the tag shows it: Hammer (an alt of Toolbox, alias TheTool) saying hi reads `[Hammer] [TheTool]: hi`.
- If they have no alias and are on an alt, the tag shows their main's name: `[Wrench] [Toolbox]: hi`. If the main has left the guild, it's the acting main.
- Achievements read the same way: `[Hammer] [TheTool] has earned the achievement …`.
- There's no tag when they're on their main with no alias, or when the tag would just repeat their own name.

An alias tag is medium blue and a main's-name tag is light blue, so you can tell a nickname from a character name at a glance. To use other colors, pick one of the swatches beside **Alias tag color** and **Main's name tag color** in the **Chat Tags** settings; a sample tag shows the color chosen. Where the game has a color picker, **Custom...** opens it for any color. The colors are saved for every character on this game install. Your own messages are tagged the same way. Characters the database doesn't know yet get no tag. The name stays clickable as usual. Tags come from your own database, so changes you make in the roster show up on the next line.

Tags are on by default. `/agf tags` or the **Chat Tags** settings turn them off, and doing it again turns them back on. The choice is saved for every character on this game install and applies from the next chat line.

On Retail, the game hides chat from add-ons during encounters and keystone runs. Those lines appear without tags, and tags return once the restriction lifts.

## Friends

The **Friends** page of the add-on's new window is the people you play with. Pin up to 5 guildmates as your **Friends**: they get the star in greet prompts, on the LFG page and in **Find guildmates**, and can have [friend greetings](#editing-greetings) of their own. Friends are kept on this game install, per guild, and aren't shared with anyone.

- **Your Friends** are on the left as small player cards, then **+ Add a friend** for each open slot. Hover a Friend for an **X** that removes them, or right-click one for **Replace...** and **Remove friend**.
- **+ Add a friend** (or **Replace...**) opens **Choose a friend**: search by alias or any character's name, and pick from the list. When the search matched only an alt, the row says which (**Alt: ...**). **Cancel** goes back.
- **Most grouped with**, under your Friends, lists the guildmates you've grouped with most who aren't Friends, with their party count. Right-click one for **Add as friend** (greyed out while all 5 slots are taken).
- Click a player to see them on the right: their name with a gold **Friend** or **Most grouped** badge, their main's level, class and rank, where they are and when they were last online, the star (click it to pin or unpin them), **Whisper** and **Invite**, and tiles for their Discord, how often and when you last grouped, and when they joined the guild. Under them, the **Characters**, **Bio**, **Grouped** (your parties together, with **Show more**) and **Log** tabs, and the **Rank** tab for officers (and on your own player), as on the Guild Roster (see [The player panel](#the-player-panel)).

The page is built when you open it, and doesn't change while it's open. **Open in Guild Fellowship**, in the game's right-click menu on a guildmate's name, opens the window on that player.

## Guild Greet

When someone joins the guild or a guild member comes online, a small prompt appears (at the left side of the screen unless you move it) with just the name they go by and a button named for the kind of greeting: **Welcome to the Guild** for someone who just joined, **Greet** for a login, or **Welcome Back**. Each button is sized to fit its label. Press it to post a random greeting of that kind to guild chat. Nothing is ever posted unless you press the button.

- **Join**: someone joins the guild. They get this instead of a login prompt.
- **Login**: the first time you see someone come online this session, however long they were away.
- **Welcome back**: someone you saw log off comes back 60 minutes or more later (you can change the minutes). Coming back sooner (a relog or a disconnect) gets no prompt.
- **Friends**: not a prompt of its own, but the words for your starred friends. When one of your [Friends](#group-friends) or Top 5 logs in or comes back, the Greet or Welcome Back prompt is the usual one, and its greeting comes from your **Friends** greetings. With Friends switched off or empty, they get your Login or Welcome back greetings, so nobody goes unprompted. Someone joining the guild always gets a Join greeting.
- People who were already online when you logged in, your own characters, and friends outside the guild never get a prompt.
- Greet works per player, so switching from a main to an alt is the same person, not a new arrival.
- A prompt shows 5 to 10 seconds (at random) after someone arrives, so your greeting doesn't reach them while their game is still loading. It disappears 90 seconds after it shows, or as soon as that person goes offline, leaves the guild or is removed from it (even before it shows); the **X** closes one without greeting.
- To move the prompts, press **Move greeting pop-ups** (in the Greetings gear menu, or the Guild Greet settings) and drag the gold bar that appears. The button then reads **Done moving**; press it to lock the prompts where they are. The place is saved for every character. The bar stays while the add-on's window is open, on any tab. Closing the window or the AddOns options also locks them, as does a reload.
- In combat or a boss encounter, prompts wait. When it's over, any that are still under 90 seconds old appear.
- On Retail, the game hides some system messages from add-ons during encounters and keystone runs. Logins it hides get no prompt; nothing breaks.

Greetings can use these placeholders, in any capitalization:

| Placeholder | Becomes |
|---|---|
| `{name}` | The player's alias, else their main's name. |
| `{main}` | Their main's name, even when they have an alias. |
| `{mainFirst}`, `{mainLast}` | The first or last part of the main's name. |
| `{character}` | The character that just logged in. |
| `{characterFirst}`, `{characterLast}` | The first or last part of that character's name. |

First and last parts only differ on WoW Forever, where names have two parts, so "Hello Mr. {mainLast}" greets Tool Box as "Hello Mr. Box". On Retail, names are one word, so `{mainFirst}` and `{mainLast}` are the same as `{main}`, and `{characterFirst}` and `{characterLast}` are the same as `{character}`. Starter greetings are included. The same greeting is never picked twice in a row. Guild Greet is on by default; turn it off in the **Guild Greet** settings. Greetings and settings are shared by every character on this game install, and **Greet from this character** turns it off on just the one you're playing, say an alt in another guild (hover its info icon for a reminder). You get no greet prompts inside dungeons, raids, battlegrounds, arenas and keystone runs, and guildmates who come online while you're inside aren't prompted for later; turn on **Greet guild members during dungeons and raids** to be prompted there too.

### Greeting together

The add-on counts greetings by reading guild chat. While your prompt for someone is up, any guild chat line that names them counts as a greeting from whoever sent it: their character's name, their main's name or their alias, as a whole word in any capitalization (on WoW Forever, either part of a two-part name works too). Greetings from Greet buttons and greetings typed by hand count alike, from members with or without the add-on. Lines that don't name them, like "wb!" or "hi all", never count, so the greetings that close your prompt are personal ones. A custom greeting of yours without a name placeholder doesn't count toward anyone else's prompt either.

Once a player has had enough greetings, your prompt for them quietly closes, and you aren't prompted for them again until the welcome-back time (60 minutes unless you changed it) has passed since the last greeting. Each person's greeting counts once, whichever of their characters sent it, and the person's own lines never count. If two people press Greet at the same moment, an extra greeting can slip through. Pressing a greeting button also sends a short add-on message, for guildmates on v0.9.4 or earlier, whose add-on counts greetings only that way; it's heard from them too. It's counted once with the same person's line in guild chat, and goes away in a later release once everyone has updated. Typing a greeting by hand sends nothing extra.

How many is enough is set on the Greetings page's **Settings** tab (or under **Close my prompt after** in the Guild Greet settings), each from 1 to 10: greetings (2 by default) for a login or welcome back, and welcomes (3 by default) for someone who just joined the guild.

After each greeting, Greet is locked for a moment so nobody floods guild chat: 2 seconds after your first greeting in a row, 4 after the second, 6 after the third, and so on. While it's locked, the greeting buttons are greyed out and count down, as **Welcome Back (3)**. Press again once they unlock; the game only lets an add-on post to chat when you press a button, so nothing is sent for you later. A prompt whose player gets enough greetings from others in the meantime closes as usual. Once a lock runs out with no prompts showing, the next one starts at 2 seconds again.

So the same few quick greeters don't take every greeting, each greeting you post adds 1 to your greet weight, up to 6. While 3 or more guildmates with the add-on are online (counting you), your new prompts wait 2.5 seconds longer per weight, up to 15 seconds, on top of the usual 5 to 10. That gives everyone else a chance to greet first: greetings during the wait count as usual, and once the person has had enough, your prompt never shows. The weight fades by 1 every 5 minutes, also while you're offline, and it's shared by all your characters. A guildmate counts once your add-on has heard theirs since you logged in (their own login announcement, their location updates, or any other add-on message), unless they're inside a dungeon, raid or other instance, where greeting is off by default. `/agf probe greet` shows where you stand.

When officers turn on **Slow mode** (1 to 15 minutes, in the Guild Greet officer settings), each greeter can greet once every that many minutes. While it's on, a small notice above your prompts says so: "Greeting Slow mode is on: you can greet once every 5 minutes." (it sits above the drag handle while you're moving the prompts). The notice and the drag handle draw on the same layer as the prompts, so the world map, your bags and other windows cover them. When several prompts are showing, pick the one you want: pressing Greet posts it and closes all your other prompts, and you get no new prompts until your cooldown ends. People who come online meanwhile are skipped, not saved for later; guildmates who aren't in a cooldown still get prompts for them. Your Frequent and Top 5 [group friends](#group-friends) are the exception. The cooldown counts from your latest Greet press, is shared by all your characters and lasts through a reload or relog. It follows the officers' current value, so lowering it shortens a cooldown already running and setting it to 0 ends it. Only pressing Greet starts it: greetings you type into guild chat yourself don't. Join welcomes are exempt: their prompts show during a cooldown, stay open when you greet someone else, and greeting one doesn't start a cooldown. The short lock after each greeting and your greet weight work as usual.

### Group friends

Guild Greet uses your [group history](#group-history) to point out the guildmates you play with. Parties count per player, across all their characters:

- **Grouped**: you've grouped with them at least once. Their name shows in blue on their prompts.
- **Frequent**: you've grouped with them 4 or more times. Their name is blue, with a star in front.
- **Top 5**: the 5 players you've grouped with most, whatever the counts. Their name is purple, with a star. Ties go to whoever you grouped with most recently. A Top 5 player isn't also counted as Frequent.

Frequent and Top 5 friends get two perks:

- Their prompts stay open until they've had twice your cap: twice the greetings for a login or welcome back, and twice the welcomes for a join.
- In Slow mode they're held instead of dropped. When you greet someone else, their prompts stay open with the greeting button locked and counting down the rest of your cooldown, as **Greet (4:32)** (whole seconds under a minute). If they come online during your cooldown, they get a prompt, locked the same way. Once the cooldown ends, greet them as usual, which starts a new cooldown. A held prompt stays until the cooldown ends and for the usual 90 seconds after. It still closes when they go offline, leave the guild or have had twice your cap.

The tiers follow your history as it grows: someone you group with for the first time is marked from then on, without a reload. **Highlight group friends** (on by default) turns the marks and the perks on or off together.

**Greet prompts for** (in the Greetings gear menu and the Guild Greet settings) chooses who you're prompted for, of every kind, join welcomes included: **Everyone** (the default), **Grouped with** (players you've grouped with at least once, and your Friends), or **My Friends** (only your 5 Friends and your Top 5). Changing it closes any prompts waiting for players who no longer fit. It works whether or not **Highlight group friends** is on, and doesn't change the caps, marks or Slow mode for the players you're still prompted for.

Greeting messages, recruitment ad times, and the officer channel probe travel apart from guild sync's traffic, so a busy sync (a big guild logging in at once) doesn't hold them up.

### Editing greetings

Greetings are edited on the **Greetings** page of the add-on's new window: `/agf greet`, **Edit Greetings** in the AddOns options, or **Greetings** in the window's sidebar. Beside the gear at the top right, **Greet prompts on** / **off** is the same switch as **Show greet prompts**; while it's off the page is dimmed but still works. The page has two tabs, **Greetings** and **Settings**.

**Greetings tab.** Pick a category at the top: **Join · Login · Welcome back · Friends**. A grey dot marks a category that's switched off or has no greetings. Under it, a line says when that category is used, beside its own switch (**Prompt me**, or **Use for friends** for Friends, which only changes the words, never whether you're prompted). A switched-off category keeps its greetings, dimmed under a short note. Then come its greetings, two lines each at most, with the whole greeting on mouseover:

- Hover a greeting for **Edit** and 🗑. **Edit** turns it into a box in place, and **+ Add a greeting** opens an empty one at the bottom. The box grows to four lines as you type. **Save** (or **Add**, for a new one) is greyed out until there's something new to save; Enter saves and Escape cancels. A greeting must fit in one guild chat message (255 characters). If it can't be saved, the reason shows under the box for a few seconds.
- Under the box, **Insert** buttons put `{name}`, `{main}` or `{character}` where your cursor is (hover one to see what it fills in), and **More ▼** has the rest. **Preview:** shows the greeting filled in with your own names.
- Only one greeting is open at a time. Switching category or tab, editing another greeting, or leaving the page drops what you typed.
- 🗑 turns into a red **Delete?**; click it again within 5 seconds to delete, or leave it and it goes back. On the last Join, Login or Welcome back greeting it reads **Delete? (last one)**, since an empty category shows no prompts. An empty category says so, with **+ Add a greeting** right there; an empty Friends category says friends get your Login and Welcome back greetings until you add one.
- When prompts are off on the character you're playing, a banner says "Greet prompts are off on <character>. Your other characters still get them.", with **Turn on**.

**Settings tab.** The numbers, written as sentences with − and + in them: hold − or + to keep going, or click the number and type one. "Count a login as a welcome back after [60] minutes away" moves in 5s, from 1 to 120. The **Close my prompt** card has "Once they've had [2] greetings" and "Once a new member has had [3] welcomes", each from 1 to 10. Officers then get a tinted **Officer · applies to the whole guild** card with the guild's **Slow mode** slider; everyone else gets one line saying what the guild's Slow mode is.

**Gear menu.** The gear opens the **Greetings** menu: **Greet from this character** and **Greet in dungeons and raids** (hover their info icons for what they do), **Highlight group friends**, **Greet prompts for: Everyone / Grouped with / My Friends**, and **Move greeting pop-ups**, which reads **Done moving** while you place them and locks them when the window closes.

Everything on the page is the same setting as in the AddOns options and the slash commands, so they always agree. Long absence greetings from older versions are deleted when you update, since that category is gone: a first login after a long time away is a Login.

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

Every post counts toward the player who made it, on all their characters together. The player panel's Log tab shows **Advertised: N (M in last 30 days)**. The 30-day number falls as ads get older, even if they don't post again. Only ads posted through the add-on are counted.

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
- Each recipient is checked just before their mail goes out. A send can resume days after its list was made, so anyone who has left the guild since (as of the last roster scan) is skipped, shown as **skipped (no longer in the guild)**, and never mailed.
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

Each guild rank can have **promotion requirements**: what a player at that rank must do to move up to the next one. Officers set them up and work through them on the **Rank management** page of [the add-on's window](#the-add-ons-window), and on the player panel's **Rank** tab. The *player* earns the rank: a player has **one rank-up checklist**, on their highest-ranked character in the guild (their main, when several share the top rank). Ticks, notes, overrides and snoozes all go on that character; the player's other characters have no checklist of their own and catch up through **Promote to match**. If another character later outranks it, the checklist moves there, starting fresh for its rank. A player who meets every requirement is **Ready**, and an officer promotes them in the game's own guild window (add-ons aren't allowed to promote). Ranks are always named by the rank promoted *to*: "→ Member".

Rank management is only shown to officers (the guild master's rank, or any rank that can view officer notes), and appears or disappears without a reload when someone is promoted or demoted. The rest of the guild only sees their own progress (see [Your own progress](#your-own-progress)).

### Due

The **Due** tab (Rank management opens on it) lists the players whose time requirements are met, so you can see who to check on:

- **Ready**: every requirement is met. The row lists the characters to promote.
- **Match**: the player's alts are behind their highest rank (see [Promote to match](#promote-to-match)). The row lists them.
- **Due**: the time is up, but something else isn't. The row says what it's waiting on ("Has a Discord name set · Interview"), with **Snooze**.

Ready comes first, then Match, then Due. The search box finds players by alias or character name, and the footer counts Ready, Match, Due and snoozed. The sidebar button counts the players due. Click a row to open that player on the Guild Roster, on the [Rank tab](#the-player-panels-rank-tab).

**Snooze** puts a Due player off for their rank's snooze length (see [Requirements](#requirements)), counted from the click, in one click. While snoozed they leave Due, and the All players tab says **Snoozed until <date> by <officer>**. Ready isn't affected: tick what was missing, and once every requirement is met they're Ready at once. When the snooze ends they're Due again if they still aren't Ready. There's no unsnooze. Snoozes are shared with every officer, including those who log in later, and only taken from officers. When two officers snooze the same character, the newest wins. A rank change clears the snooze.

### Promote to, and the grid

**Promote to** picks one rank (or **Any rank**). The list narrows to the players up for it and becomes a grid, with a column per requirement of the rank:

- An automated cell is green when it's met and red when it isn't, with the add-on's detail ("44 d", "≈12 d" for an approximate date, "level 66", "not seen", "seen 3 d ago", "not set").
- An officer check is a check box, ticked or unticked at once with no confirm. A check that needs a note asks for it first (**Save** ticks it, **Cancel** leaves it unticked). A ticked check shows its note, or who ticked it.
- Right-click a red cell for **Override as met…**, with an optional reason: the cell turns gold and reads "met by override". Right-click a gold cell for **Remove override**.

**Missing** picks one requirement of the picked rank (or of every rank, for Any rank) and keeps only the Due players missing it. A chip with an **X** names it, its column's header is highlighted, and the footer counts them: "9 of 22 players due → Member are missing: Has a Discord name set".

### All players

The **All players (N)** tab lists every player in the guild with their standing in words: **Ready**, **Match**, **Due**, **Snoozed until <date> by <officer>**, **Not yet: N days** (counting down to the last time requirement still open), or **No requirements**. The soonest come first. **All**, **Snoozed** and **Not yet** filter it.

### Requirements

The **Requirements** tab is the editor. Every rank starts with no requirements, so nothing changes until your guild sets them up. On the left, each rank is listed by the rank it promotes to ("→ Member") with how many requirements it has; click one to edit it.

- **Automated checks** are switches, each with a number (days or a level) where it takes one:
  - **Character days in guild**: this character has been in the guild at least N days.
  - **Player days in guild**: the player has, counted from the earliest join among their characters still in the guild, so a long-time member's new alt doesn't have to wait.
  - **Days at rank**: the character has held its current rank at least N days.
  - **Character level**: the character is at least level N.
  - **Has the Guild Fellowship Addon**: any of the player's characters has been heard on the add-on.
  - **Has a Discord name set**: the player has a Discord name on file, set on any of their characters.
- Switching a check off deletes it, along with any overrides on it.
- **Officer checks** are the ones an officer ticks. **Add check** and **Add check needing a note** ask for the text (a note holds up to 100 characters, such as which event the member attended). Each has ▲ ▼ to reorder it, **Rename**, and **Delete**, which asks first: every tick and note on it is dropped too.
- **Alts should match this rank** (see [Promote to match](#promote-to-match)), and the **Snooze length (days)**: 1 to 90, 7 by default. Changing it only affects new snoozes.
- If the guild master inserts or removes a rank, requirements stay with their rank's position, and the editor warns when the rank there now has a different name, so you can check they still belong.

Requirements reach every add-on in the guild through [guild sync](#guild-sync). When two officers edit the same item, the newest edit wins everywhere. Changes are only taken from an officer's add-on, so nobody else can send one, even in an officer's name. An add-on that logs in catches up from an officer online.

### Ready for promotion

A Ready player is on Rank management's Due tab, and their characters to promote show an up arrow just after their rank in **the game's guild roster**. Promote them in that window. `/agf probe ready` says how many are ready, whether the roster's rows are being followed, and how many flags sit next to the rank (open the guild roster first). A row whose rank isn't shown gets the arrow at its right edge instead, beside the yellow out-of-date note marker.

Any rank change, up or down, clears that character's ticks, notes and overrides. A character promoted and later demoted back to a rank starts that rank's checklist afresh. That holds even on an officer's add-on that was offline the whole time, once the guild log (or an officer's date) shows when it came back to the rank.

### Promote to match

When a player has characters at different ranks, officers see each alt that's behind flagged with the rank to promote it to so it matches the player's highest, for example **Promote to match: Officer**. The highest rank among the player's characters still in the guild sets it, whichever character holds it. The guild master's rank is never a target, since a guild has only one guild master: the guild master's alts are matched to the rank just below it. The flag doesn't depend on promotion requirements, so it shows even for an alt whose rank has none. It clears by itself once the alt reaches the rank, including when it's promoted in the game's own guild window.

The flag shows in three places:

- **Rank management**: the player's **Match** row lists the alts to bring up.
- **The panel under the game guild roster's member details**, when that alt is selected, saying which rank and why, for example **Promote to Officer to match Toolbox (Guild Master), this player's highest.** It shares the panel with the [out-of-date note](#out-of-date-guild-notes) suggestion when both apply.
- **The game's guild roster list**, as the same up arrow as Ready for promotion, tinted blue. Hover it for the rank, for example **Promote to match: Officer**. An alt that's both behind and ready shows the blue arrow. `/agf probe ready` counts the alts to promote to match, lists each with its target rank, and says how many rows show the blue arrow.

Members never see match flags.

Each rank in Rank management's [Requirements](#requirements) tab has an **Alts should match this rank** switch. It's ticked by default. Untick it and alts aren't matched to that rank: an alt is flagged with the next rank down that's still ticked, and isn't flagged at all when none between it and the player's highest rank are. For example, untick Officer, and an Officer's alt at Member is flagged **Promote to match: Veteran**. The setting is shared with every officer, the newest change wins, and flags update as soon as it changes. The guild master's rank has no switch, since alts are never matched to it.

### The player panel's Rank tab

The [player panel](#the-player-panel) on the Guild Roster and the Friends page has a **Rank** tab for officers on anyone, and for a member on their own player only. It shows the player's standing and the rank promoted to ("Due · → Member"), the characters to promote, and each requirement with its detail ("30 days (needs 7)", "level 66 of 70", "met by override · Levels on an alt", or who ticked a check and its note). Officers work on it there as in the grid: tick checks (one that needs a note asks for it), right-click a failed automated requirement to override it or take the override back, and **Snooze** a Due player.

Ticks, notes and overrides reach every officer's add-on through guild sync, including officers who were offline, who catch up when they log in. They're only taken from an officer's add-on, so nobody can tick their own items, even in an officer's name.

### Your own progress

A member sees the Rank tab on their own player only, read-only: their standing, and each requirement toward the next rank with whether it's met and its progress. It says "Only officers can change this checklist." and never shows anyone else's progress.

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
- The **Guild Log** tab lists entries newest first: the date, what happened, the character, its player, and who did it. What happened is colored by event type: joins green, invites teal, leaves orange, kicks red, promotions blue and demotions purple.
- **Sort** switches between date and name. **Range** steps through all, the last 7, 30 and 90 days. A check box for each event type (Join, Invite, Leave, Kick, Promote, Demote) shows or hides it; each label is in its type's color.
- Search by character name, alias or main: all of a player's characters show together.
- Long logs come in pages (`<` and `>`), so even thousands of entries stay smooth.

Where the game's guild event log can't be read, everything still works from live events, roster scans, sync and hand-set dates. `/agf probe log` reports what the game's event log gives the add-on, and `/agf probe officer` checks the officer channel.

### Welcome mail

Officers can set up one guild **Welcome mail** for newcomers. **Welcome mail**, beside **New** in the mailbox's Guild Mail tab, opens its page in the Guild Mail window: a subject and message (with the same placeholders and limits), **Save**, and **Send the welcome mail to newcomers**, which starts off. The page shows the welcome as your own character would get it. Saved text is shared with every officer's add-on through guild sync, the newest change winning, so whoever sends it sends the guild's current text. Only officers can change it.

While it's on, a character your add-on first sees in the guild (the "has joined the guild" message, or new in a roster scan) is due a welcome **24 hours** later, so there's time to link an alt. When it's due it's left out if it turns out to belong to someone already in the guild, or already welcomed, even if their other character has since left. Each player gets one welcome, on their main if they have one, else on their first character seen. Someone who left before they were due is dropped. A character the add-on already knew is rejoining, not new, and the guild's very first scan never counts.

Due welcomes collect in a **Welcome mails** row in the Guild Mail tab, and the tab's title counts them: **Guild Mail (3)**. The row reads "Welcome mails: 3 waiting", with **Edit** (the welcome mail's page), **View** and **Send**. Send fills each one in with the welcome mail as it is then, and sends them like any other mail, pausing at the limit and kept across reloads. Each welcome that goes is shared with the other officers' add-ons, which drop that player from their own Welcome mails, so nobody is welcomed twice (unless two officers press Send within seconds of each other). Switching welcome mail off adds nobody new; welcomes already waiting stay until sent or cancelled, and cancelled ones aren't due again.

## Guild LFG Board

The **Guild LFG Board** (**LFG** where space is short) shows the parties your guildmates are forming, and lists yours. Listings come from parties, not forms, and a party is never listed without your yes: list it yourself, or turn on **Auto-list my parties**. Nobody ever gets a prompt they didn't ask for: you **Ask to join** a listing, and the leader decides.

Only guildmates with the add-on see the board. To reach the others, use [Ask in guild](#ask-in-guild).

### The LFG button

A small rounded button with a tree sits wherever you drag it (saved per character). It's separate from the minimap button, which stays as it is.

- A **gold count** in its corner shows how many listed groups the character you're on could join.
- A **gold glow** means a group you could join appeared since you last opened the drawer, with one pulse per new group. There's no glow while you're in a party, in combat, in an instance or in [Do Not Disturb](#do-not-disturb). For a chat line too, turn on the new-groups chat line in the LFG settings.
- An **orange glow** means someone left your full party (see [Someone leaves](#someone-leaves)).
- **Right-click** it for **Open Guild LFG Board**, **Show Nearby** and **Hide LFG button**. **Show Nearby** opens the drawer on the guildmates in your zone, one per line with their level, each name a menu to whisper them. Hiding it means "not taking part right now": it stays hidden on that character until you type `/agf lfg` or turn **Show LFG button** back on. Your party is still listed with a best guess, but nothing asks you anything, and guildmates whisper you instead of asking to join.

### The drawer

Click the button to slide a small drawer out to its left; click again, or its **X**, to close it. Click anywhere in it other than a button to open the full board.

- **Not in a party:** the newest group you could join, with **Ask to join**, and **Start a group** under it (or "No groups for you right now").
- **In a party:** your party's purpose, size, the roles it needs, and its note, with its slots as on your listing's card: a dungeon's Tank, Healer and DPS tiles with their icons (open ones in color, filled ones grey), a person tile per player otherwise.
- **While you're being asked something** (what your party is for, whether to list a party with players outside the guild, or whether to fill an empty slot), the question and its answers. A questing listing stays in its zone when you move; **Edit** it to change the zone.

Long names wrap onto more lines at the spaces between words, and the drawer grows to fit.

### The window

`/agf lfg` and **Open Guild LFG Board** open the add-on's new window on the board. It has one size and can be dragged. The sidebar has the add-on's name, then **Friends** (see [Friends](#friends)), **LFG** and **Greetings** (see [Editing greetings](#editing-greetings)), and **Settings** at the bottom, with your character and the add-on's version under it. The **gear** at the top right opens the LFG settings (**Show LFG button**, and the chat line for new groups); the **X** closes the window. The Settings page has a **Chat** tab with the chat tags switch, the same setting as `/agf tags`, and the **Alias tag color** and **Main's name tag color**: click a swatch, or **Custom...** for any color from the game's color picker, and the sample shows the tag in that color. They're the same colors as in the old window's options.

### The board

At the top is **your party's card**:

- **Solo:** **Start a group**, which lists you as a group of one. Your listing becomes your party's when someone joins, and ends after 30 minutes with nobody joining (a chat line tells you).
- **Leading an unlisted party:** **Your party is Playing**, with **Open to guild** (it lists your party, so guildmates can ask to join). Guildmates see it as [Playing](#playing-parties) meanwhile.
- **Leading** an open party (or the guild contact of a party whose leader isn't in the guild): **Open to the guild**, your listing as others see it, with **Edit**, **Ask in guild**, **Find guildmates** and **Stop looking** (your party stays together but shows as Playing). **Find guildmates** (while your party is open and has room; greyed out otherwise, and on a Playing party with "Open your party to the guild to find guildmates") opens a list in place of the board: guildmates online now whose level is in your listing's range and, for a dungeon, who play a role still open, each with **Invite** and **Whisper**. Then offline characters that fit, whose player is online on another character, shown as "Bobalt (22 Priest) · alt of Bob, online as Bobmain": their **Whisper** goes to the online character with a request to log over typed in, for you to send or not. You, your other characters and everyone in your party are left out; guildmates already in a listed group are marked "In a group" and listed last. Online guildmates come before alts, and within each your starred friends (a Friend or a Top 5) come first, marked with the star. The drawer's party section has the same **Find guildmates** button, which opens the board on the list. The list is built when it opens; **Back** returns to the board. **Edit** opens it in the card: **What's it for?** — **Dungeon** (search the list; dungeons that fit your level come first, and typing finds any dungeon), **Questing** (pick a zone from the list, your current zone chosen to start; zones that fit your level come first, the rest under Other levels, and the listing takes the zone's level range, or your party's levels 5 either way when the game has none), **Raid**, or **Other** (your own words) — and a **Note** of up to 60 characters. **Roles in your party** shows each member's role icon by their name; click a name to set their role from the ones their class plays. The leader (or contact) sets anyone's; in someone else's party, **My role** on the party's listing sets your own, and the listing shows it once the leader's add-on hears it. A role set here wins over the game's party menu, and is forgotten when that member leaves. Without one, a member's role is the game's party menu role, then their own role preference, then the first their class plays.
- **In someone else's party:** the listing, read-only.

Below it are four tabs:

- **Relevant Parties · N:** large gold-bordered cards for groups you could join on this character: the purpose, level range and size; the members in class color, each with their role's icon in a dungeon (a crown for the leader, a star for your Top 5 [group friends](#group-friends)); role tiles on the right with their icons (open roles in color, filled ones grey); the note, **Ask to join** and **Whisper**. Then, under **Your alts could join**, small cards with the type, levels and leader (in class color; click to whisper) and a row of small role tiles.
- **Nearby · N:** a **Nearby in <zone>** card listing the guildmates in your zone, one per line, their levels in a column left of their names in class color, for finding people to quest with.
- **Other Parties · N:** small greyed cards for full groups and groups nothing of yours fits, then under **Playing** the [Playing parties](#playing-parties).
- **History:** your own recent parties, newest first, 20 at a time with **Show more**: the date, the dungeon when known, and the guildmates, with a star for Top 5 group friends (see [Group history](#group-history)).

Click any name on the board (a card's members, Nearby, History) for a menu with the name at the top and **Whisper** under it. A click anywhere outside the menu closes it.

A dungeon is relevant when your level fits and a role you play (by your [role preferences](#role-preferences)) is open; questing when your level fits the zone and there's room; a raid or other purpose when you fit its level range, or always for a raid with none.

### Listing your party

- **Auto-list my parties** (in the LFG gear menu and the AddOns options) is **off by default**. Off, a party you form or come to lead isn't listed and you aren't asked anything: list it from the board's **Start a group** when you want to. A party filling up never lists it either.
- **With Auto-list on**, becoming a party's leader (inviting someone, or being promoted in an unlisted party) lists it straight away for what it looks like it's for: the dungeon you're in, else questing in your zone, updated when you enter a dungeon (a purpose you set yourself is left alone). When the add-on can't tell, the drawer asks what it's for; ignoring the question means **Not looking**, which keeps it off the board, and there's a "don't ask for 30 minutes" choice for quick trading parties. **Not looking** or **End listing** keeps that party off the list for good.
- **A party with players outside the guild** (with Auto-list on) asks first whether to list it at all. If the leader isn't in the guild, the first guildmate to answer becomes the listing's contact.
- With your LFG button hidden, nothing is listed; with Auto-list on, a chat line says your party wasn't listed and how to list it.
- Taking over a listed party's lead keeps its listing, Auto-list or not.
- A listing goes as soon as its party disbands or its leader chooses **Stop looking**, and after 5 minutes without word from its party's add-ons. If its leader or contact logs off, it's handed to another guildmate in the party.

### Playing parties

A party you lead with a guildmate in it shows on the guild's boards as **Playing** while it isn't open to the guild, so everyone can see what the guild is up to: where it is (the dungeon, else the zone), how many are in it, and its leader. Nobody can ask to join a Playing party. Open it to the guild and it's an open listing instead; **Stop looking** and it's Playing again. It goes when the party breaks up, or after 5 minutes without word from it.

**Show my party on the guild's board** (in the LFG gear menu and the AddOns options) is **on by default**. Turn it off to keep your party to yourselves until you open it; it leaves guildmates' boards at once. Only the party's leader's add-on shares it, and older versions of the add-on don't show Playing parties.

### Someone leaves

When someone leaves your full party, your button glows orange and the drawer asks **Someone left — fill the empty slot?** with the open role. **Yes** posts the slot; **No** keeps the party listed as it was. Nothing is posted without an answer: the question waits, glowing orange, until someone answers, the party fills again, someone else leaves, or it disbands. With the button hidden, the leader gets a chat line pointing to `/agf lfg` instead, and nothing is posted.

### Ask to join

**Ask to join** is for the character you're on. For a dungeon you pick the open role you'd fill; to bring an alt, whisper the leader. The button then shows **pending**, **accepted**, **declined** or **expired**. When the leader's add-on can't take requests (a leader outside the guild, or one who hid the button), you get **Whisper** instead.

The leader's drawer opens and the request slides out under it, such as **Hammer — Healer, 24**, with **Invite** (the game's party invite) and **Decline**. Requests stack, expire after 2 minutes, and are declined with "role filled" when their role fills, or all of them when the party fills. Requests to a leader in Do Not Disturb are declined automatically.

### Ask in guild

**Ask in guild** on your party's card opens guild chat with a ready-made line, for example **LF healer and 2 DPS for Stratholme (58–60), whisper me!**: the open roles for a dungeon, otherwise how many players you need. Change it as you like and press Enter, or Escape to send nothing. The add-on never posts it for you.

### Do Not Disturb

Turn on **Do Not Disturb** when you don't want group glows or requests. It's in three places that always agree: the check box at the bottom of [My Profile](#my-profile), **Do Not Disturb** in the settings, and `/agf dnd`. It applies to every character on your account. While it's on, the LFG button doesn't glow for new groups, and [Ask to join](#ask-to-join) requests to you are declined automatically.

The button never glows while you're in a party, in combat or inside an instance either, with nothing to turn on.

### Role preferences

Each character has its own role preferences: the roles you're willing to play on it. They start as every role its class can fill. To turn one off (say, a paladin you never heal on), log into that character and untick it on the [My Profile](#my-profile) tab. Only the roles that character's class can fill are listed. The player panel's **Characters** tab shows each character's role preferences.

Your role preferences reach the whole guild through [guild sync](#guild-sync), even while you're on another character or offline. Only the character itself can set them, not officers or anyone else. If your add-on sees a change in your character's name that you never made, it sends your real preferences back out to correct it, and warns you who passed it on.

### Group history

Your add-on remembers, on your computer only, each party you've been in with guildmates: any party, not just listed ones. It records when, which guild characters, and the dungeon when it knows it (the one your party is listed for on the [Guild LFG Board](#guild-lfg-board), or the instance you're in). Guildmates joining later count as the same party, and so does reloading while in it. Your own alts never count. The history is never sent to anyone.

A guildmate's player panel then shows **3 times** on its **Grouped** tile, counted across all their characters, the parties on its **Grouped** tab, and when you last grouped. Players you've never grouped with show **Never**. Guild Greet uses the same history to mark your [group friends](#group-friends) on their prompts. The history is never trimmed, however long it gets.

## Guild map

Guildmates running the add-on share where they are, so you can see where the guild is playing and find people to meet up with.

- **Zone map and minimap**: each guildmate in that zone is a dot in their class color at their exact position. Dots that would cover each other are moved apart by a dot's width. On the minimap you see the guildmates in your own zone.
- **Continent map**: each zone with guildmates has one marker, placed where they are in that zone. One guildmate shows as a dot in their class color; 2 or more show as a count. Point at a zone with a count to list its guildmates at the right of the map.
- **World map**: one marker per continent, over its land (Kalimdor and the Eastern Kingdoms have fixed spots). Point at a continent with a count to list its guildmates under its name.
- Hover a single guildmate's dot to see their name, alias or main (the same as their [chat tag](#chat-tags)) and level, as `Name (Main) (70)`. A count has no tooltip of its own: its area's list shows everyone there.
- Guildmates without the add-on, and those whose position hasn't arrived yet, still count on the continent and world maps at zone level, using the zone the guild roster shows. On their zone's own map each gets a dot at the zone's center, since the roster names only the zone; its tooltip ends with **(exact location unknown)**. They never get a dot on the minimap.
- Guildmates in your party or raid (any subgroup) get no dot on the zone map or minimap, since the game already marks them. They still count in the continent and world map markers and their hover lists. Their dot comes back as soon as they leave your group.
- While you're in a party or raid, guildmates outside it are slightly dimmed on every map and the minimap. A marker with nobody from your group is dimmed as a whole.
- Your own characters never show.

Every guildmate's dot updates about every 2 minutes, and promptly after a zone change. Between updates, a dot shows where they were at their last one. (Faster updates for guildmates in your zone are turned off for now: they were whispered, and a whisper to someone who had just logged off showed the sender "No player named ... is currently playing.")

A dot disappears when the guildmate:

- enters a dungeon, raid, battleground or arena (they come back when they leave),
- turns sharing off,
- hasn't sent an update for 5 minutes, or
- logs off or leaves the guild (as soon as the game says so, or the guild roster shows it).

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

These belong to your player, not to one character: whichever of your characters you're on, you see and edit the same values, and the newest edit wins. They're saved and sent to the guild at once, with no officer approving them, and only your own characters and officers can change your location and bio (officers from your player panel's **Bio** tab). Your Discord name can also be set or cleared by an officer with **Set Discord…** (in the player panel's **⋯** menu). Other members can't change any of them. If someone's add-on passes on a change in your name that you never made, yours sends your real values back out, and you're warned who passed it on, as for role preferences. Guildmates see your Discord on your player panel's **Discord** tile, and your location and bio on its **Bio** tab, where you can also edit them.

### Characters and roles

Under each character are its [role preferences](#role-preferences). The character you're logged in on has a check box for each role its class can fill. Ticking one changes it, and the guild hears about it through [guild sync](#guild-sync). Your other characters' roles are shown but can't be changed here: log in on that character to change them.

Along the bottom is the **Do Not Disturb** check box, the same setting as in the settings and `/agf dnd` (see [Do Not Disturb](#do-not-disturb)).

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
| `Forever` (default) | `C:\Program Files (x86)\World of Warcraft\_forever_` |
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

The development build also has testing commands the production build leaves out:

- `/agfdev greettest` shows a greet prompt right away in each look: never grouped with, Grouped, Frequent and Top 5, so you can see them without waiting for a friend to log in. Each tier shows a guildmate really in it when your party history has one, and otherwise another guildmate drawn in that tier's look (chat marks them "stand-in"). **Greet** on a test prompt posts nothing to guild chat and just closes it. `/agfdev greettest hold` shows the Frequent and Top 5 prompts held as in Slow mode, counting down 30 seconds.
- `/agfdev lfgtest` fills your Guild LFG Board with stand-in listings for every look: relevant ones (one with a note, and a raid), one only an alt of yours fits (when you have an alt far enough from your level), one nothing of yours fits, and a full one. It also glows the LFG button orange with a stand-in **Someone left — fill the empty slot?**, slides out a stand-in Ask to join request, and adds stand-in guildmates (one an alt) to **Find guildmates**. Nothing about the stand-ins is ever sent: asking to join one, **Invite**, **Decline**, **Yes** and **No** only print a line in chat. The stand-in listings leave the board after 5 minutes.
- To test with your production party history, quit WoW, copy `AsgardsGuildFellowship.lua` in `WTF/Account/<ACCOUNT>/SavedVariables/` to `AsgardsGuildFellowshipDev.lua`, and change its first line to `AsgardsGuildFellowshipDevDB = {`.

## Running the tests

The tests need only Lua 5.1:

```sh
lua5.1 tests/run.lua
```

CI runs the same suite, a syntax check of every add-on Lua file, and the library pin check in the `Lua 5.1` job. The tests stand in for the libraries, so they don't need `Libs/`.

The release tools have their own shell tests in `tests/tools/` (run any of them directly, for example `tests/tools/set-interface.test.sh`). CI runs them in the **Release package** job; see [docs/packaging.md](https://github.com/FinalAsgard/asgards-guild-fellowship/blob/main/docs/packaging.md).
