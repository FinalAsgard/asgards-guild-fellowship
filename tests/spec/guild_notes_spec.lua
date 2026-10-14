local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/NoteWriter.lua",
        "Core/NotePlan.lua",
        "Core/GuildNotes.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua"
    )
end

-- NoteWriter -------------------------------------------------------------------

local RETAIL = { twoPartNames = false }
-- Forever: "Tool Box" and "Hammer Smith" are characters.
local FOREVER = {
    twoPartNames = true,
    isName = function(text)
        local lower = string.lower(text)
        return lower == "tool box" or lower == "hammer smith"
    end,
}

test.test("note writer: the wanted markers go first, and the rest of the note follows", function()
    local NoteWriter = load().NoteWriter

    test.assertEqual(">Hammer Healer", NoteWriter.Write("Healer >Toolbox", { main = "Hammer" }, RETAIL))
    test.assertEqual("@TheTool raid lead", NoteWriter.Write("raid lead", { alias = "TheTool" }, RETAIL))
    test.assertEqual(">Toolbox", NoteWriter.Write("", { main = "Toolbox" }, RETAIL))
    test.assertEqual(">Toolbox", NoteWriter.Write(nil, { main = "Toolbox" }, RETAIL))
end)

test.test("note writer: removes every main and alias marker form, in any case, anywhere", function()
    local NoteWriter = load().NoteWriter
    local cases = {
        { "Main: Toolbox, tank", "tank" },
        { "MAIN: >Toolbox tank", "tank" },
        { "tank main:Toolbox", "tank" },
        { "Alias: TheTool heals", "heals" },
        { "heals alias: @TheTool", "heals" },
        { "@TheTool >Toolbox heals", "heals" },
        { ">Toolbox heals >Wrench @Old", "heals" },
        { ">Toolbox-Stormrage. heals", "heals" },
    }
    local index
    for index = 1, #cases do
        test.assertEqual(">Hammer " .. cases[index][2],
            NoteWriter.Write(cases[index][1], { main = "Hammer" }, RETAIL), cases[index][1])
    end
    -- No markers wanted (a split-off character): only the free text stays.
    test.assertEqual("Healer", NoteWriter.Write("Healer >Toolbox", {}, RETAIL))
    test.assertEqual("", NoteWriter.Write(">Toolbox", {}, RETAIL))
    -- "Domain:" isn't a Main: label, so it's kept.
    test.assertEqual(">Hammer Domain: pvp", NoteWriter.Write("Domain: pvp", { main = "Hammer" }, RETAIL))
end)

test.test("note writer: a note that already says it is left alone", function()
    local NoteWriter = load().NoteWriter

    local note, cut = NoteWriter.Write(">Toolbox Healer", { main = "Toolbox" }, RETAIL)
    test.assertEqual(nil, note)
    test.assertFalse(cut)
    -- The right markers anywhere, in another form or case, count too.
    test.assertEqual(nil, NoteWriter.Write("Healer >toolbox", { main = "Toolbox" }, RETAIL))
    test.assertEqual(nil, NoteWriter.Write("Main: Toolbox", { main = "Toolbox" }, RETAIL))
    test.assertEqual(nil, NoteWriter.Write("raid lead @TheTool", { alias = "TheTool" }, RETAIL))
    test.assertEqual(nil, NoteWriter.Write("Healer", {}, RETAIL))
    -- A second marker, or a missing one, means it's rewritten.
    test.assertEqual(">Toolbox", NoteWriter.Write(">Toolbox >Toolbox", { main = "Toolbox" }, RETAIL))
    test.assertEqual("@TheTool", NoteWriter.Write("@thetool", { alias = "TheTool" }, RETAIL))
end)

test.test("note writer: free text is cut to fit the length limit, never inside a character", function()
    local NoteWriter = load().NoteWriter

    local note, cut = NoteWriter.Write("Alchemy 300 and Herbalism 300 raider", { main = "Toolbox" }, RETAIL)
    test.assertEqual(">Toolbox Alchemy 300 and Herbal", note)
    test.assertEqual(31, #note)
    test.assertTrue(cut)

    -- "é" is two bytes: a cut through it moves back before it.
    note, cut = NoteWriter.Write("abcdefghijklmnopqrstuéz", { main = "Toolbox" }, RETAIL)
    test.assertEqual(">Toolbox abcdefghijklmnopqrstu", note)
    test.assertTrue(cut)

    note, cut = NoteWriter.Write("short", { main = "Toolbox" }, { maxLength = 20 })
    test.assertEqual(">Toolbox short", note)
    test.assertFalse(cut)

    -- Markers that don't fit at all aren't written.
    local _, _, problem = NoteWriter.Write("", { main = "Averyveryverylongname-Stormrage", alias = "Alias" }, RETAIL)
    test.assertEqual("too long", problem)
end)

test.test("note writer: Forever names are first and last, and removed whole", function()
    local NoteWriter = load().NoteWriter

    test.assertEqual(">Hammer Smith Healer", NoteWriter.Write(">Tool Box Healer", { main = "Hammer Smith" }, FOREVER))
    test.assertEqual(">Tool Box Healer", NoteWriter.Write("Main: Hammer Smith, Healer", { main = "Tool Box" }, FOREVER))
    -- A first name alone: only it is part of the marker.
    test.assertEqual(">Hammer Smith Healer", NoteWriter.Write(">Tool Healer", { main = "Hammer Smith" }, FOREVER))
    test.assertEqual(nil, NoteWriter.Write("Healer >Tool Box", { main = "Tool Box" }, FOREVER))
end)

test.test("note writer: a written note is read back to the same main and alias", function()
    local addon = load()
    local resolver = function(text)
        local lower = string.lower(text)
        if lower == "tool box" or lower == "toolbox" then
            return { "toolbox" }
        end
        return {}
    end

    local note = addon.NoteWriter.Write("Healer Main: Wrench", { main = "Tool Box" }, FOREVER)
    local parsed = addon.NoteParser.Parse(note, resolver, FOREVER)
    test.assertEqual("toolbox", parsed.mainRef.key)

    note = addon.NoteWriter.Write("raid lead Alias: Old", { alias = "TheTool" }, RETAIL)
    parsed = addon.NoteParser.Parse(note, resolver, RETAIL)
    test.assertEqual("TheTool", parsed.alias)
    test.assertEqual(nil, parsed.mainRef)
end)

-- NotePlan ---------------------------------------------------------------------

local RULES = { twoPartNames = false, homeRealm = "Area52" }

-- TheTool: Toolbox (main) + Hammer; Wrench and Visitor-Stormrage on their own.
local function organized()
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = "Area52" })
    local normalizer = addon.NameNormalizer.Create(RULES)
    local members = {}
    local entries = {
        { "Toolbox-Area52", "@TheTool" },
        { "Hammer-Area52", ">Toolbox" },
        { "Wrench-Area52", "" },
        { "Visitor-Stormrage", "" },
    }
    local index
    for index = 1, #entries do
        members[normalizer:Key(entries[index][1])] = { name = entries[index][1], note = entries[index][2], level = 60 }
    end
    addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
        partition = partition, members = members, normalizer = normalizer,
        rules = RULES, mode = "initial", now = 1790000000,
    }))
    local service = addon.PlayerService.Create(partition)
    return {
        partition = partition,
        service = service,
        plan = function(keys)
            local set = {}
            for index = 1, #keys do
                set[keys[index]] = true
            end
            local described = {}
            local plan = addon.NotePlan.Build(partition, set, normalizer)
            for index = 1, #plan do
                local markers = plan[index].markers
                table.insert(described, plan[index].name .. "=" .. (markers.main and (">" .. markers.main) or "")
                    .. (markers.alias and ("@" .. markers.alias) or ""))
            end
            return table.concat(described, " ")
        end,
    }
end

test.test("note plan: linking an alt gives it its main's marker, and the main its alias", function()
    local world = organized()
    local playerId = world.partition:GetCharacter("toolbox-area52").player

    test.assertTrue(world.service:SetMainPlayer("wrench-area52", playerId))

    test.assertEqual("Hammer=>Toolbox Toolbox=@TheTool Wrench=>Toolbox",
        world.plan({ "toolbox-area52", "hammer-area52", "wrench-area52" }))
    -- A main on another realm is named with it.
    test.assertTrue(world.service:SetMainPlayer("wrench-area52",
        world.partition:GetCharacter("visitor-stormrage").player))
    test.assertEqual("Wrench=>Visitor-Stormrage", world.plan({ "wrench-area52" }))
end)

test.test("note plan: switching main moves the markers", function()
    local world = organized()

    test.assertTrue(world.service:MakeMain("hammer-area52"))

    test.assertEqual("Hammer=@TheTool Toolbox=>Hammer", world.plan({ "toolbox-area52", "hammer-area52" }))
end)

test.test("note plan: a split-off character's main marker is removed", function()
    local world = organized()

    test.assertTrue(world.service:Detach("hammer-area52"))

    test.assertEqual("Hammer= Toolbox=@TheTool", world.plan({ "toolbox-area52", "hammer-area52" }))
end)

test.test("note plan: setting or clearing an alias changes the main's marker", function()
    local world = organized()

    test.assertTrue(world.service:SetAlias("hammer-area52", "Hammers"))
    test.assertEqual("Toolbox=@Hammers", world.plan({ "toolbox-area52" }))
    test.assertTrue(world.service:SetAlias("hammer-area52", ""))
    test.assertEqual("Toolbox=", world.plan({ "toolbox-area52" }))
    -- An alias of several words can't be read back from a note.
    test.assertTrue(world.service:SetAlias("hammer-area52", "The Tool"))
    test.assertEqual("Toolbox=", world.plan({ "toolbox-area52" }))
end)

test.test("note plan: characters no longer in the guild are left out", function()
    local world = organized()
    world.partition:GetCharacter("hammer-area52").departed = 1790000000

    test.assertEqual("Toolbox=@TheTool", world.plan({ "toolbox-area52", "hammer-area52", "nobody-area52" }))
end)

-- GuildNotes -------------------------------------------------------------------

-- A roster of `notes` (key -> note), with timers run by hand.
local function newNotes(notes, options)
    options = options or {}
    local addon = load()
    local world = { notes = notes, writes = {}, messages = {}, timers = {}, busy = false }
    local order = {}
    local key
    for key in pairs(notes) do
        table.insert(order, key)
    end
    table.sort(order)
    world.guildNotes = addon.GuildNotes.Create({
        canEdit = function()
            return options.canEdit ~= false
        end,
        find = function(wanted)
            local index
            for index = 1, #order do
                if order[index] == wanted then
                    return index, world.notes[wanted]
                end
            end
            return nil
        end,
        write = function(index, note)
            world.notes[order[index]] = note
            table.insert(world.writes, order[index])
            return true
        end,
        rules = function()
            return RETAIL
        end,
        busy = function()
            return world.busy
        end,
        after = function(_, callback)
            table.insert(world.timers, callback)
            return true
        end,
        print = function(message)
            table.insert(world.messages, message)
        end,
    })
    world.tick = function()
        local due = world.timers
        world.timers = {}
        local index
        for index = 1, #due do
            due[index]()
        end
    end
    return world
end

local function entry(key, markers)
    return { key = key, name = key, markers = markers }
end

test.test("guild notes: writes a few notes at a time, then sums up once", function()
    local world = newNotes({ a = "", b = "", c = "", d = "Healer >X", e = ">Main" })
    world.guildNotes:Write({
        entry("a", { main = "Main" }), entry("b", { main = "Main" }), entry("c", { main = "Main" }),
        entry("d", { main = "Main" }), entry("e", { main = "Main" }), entry("missing", { main = "Main" }),
    })

    test.assertEqual("a,b,c", table.concat(world.writes, ","))
    test.assertEqual(0, #world.messages)
    world.tick()

    -- e was already right; missing isn't in the roster.
    test.assertEqual("a,b,c,d", table.concat(world.writes, ","))
    test.assertEqual(">Main Healer", world.notes.d)
    test.assertEqual(1, #world.messages)
    test.assertEqual("Guild notes: 4 updated. Not written: missing (not in the guild roster).", world.messages[1])
end)

test.test("guild notes: waits while the player is busy", function()
    local world = newNotes({ a = "" })
    world.busy = true

    world.guildNotes:Write({ entry("a", { main = "Main" }) })
    test.assertEqual(0, #world.writes)
    world.tick()
    test.assertEqual(0, #world.writes)

    world.busy = false
    world.tick()
    test.assertEqual(">Main", world.notes.a)
end)

test.test("guild notes: says which notes were cut, and nothing when all were already right", function()
    local world = newNotes({ a = "Alchemy 300 and Herbalism 300 raider", b = ">Main" })

    world.guildNotes:Write({ entry("a", { main = "Main" }), entry("b", { main = "Main" }) })

    test.assertEqual("Guild notes: 1 updated. Cut to fit: a.", world.messages[1])
    world.guildNotes:Write({ entry("b", { main = "Main" }) })
    test.assertEqual(1, #world.messages)
end)

test.test("guild notes: without permission nothing is written and the officer is told", function()
    local world = newNotes({ a = "" }, { canEdit = false })

    world.guildNotes:Write({ entry("a", { main = "Main" }) })

    test.assertEqual(0, #world.writes)
    test.assertEqual("Guild notes weren't updated: your rank can't edit public notes.", world.messages[1])
end)

-- The whole add-on, with a fake game that keeps written notes ---------------------

local function noteGuild()
    return {
        name = "Knights of Camelot",
        realm = "Area 52",
        members = {
            { name = "Toolbox-Area52", class = "WARRIOR", level = 80, rank = 1, rankName = "Officer",
                online = true, zone = "Dornogal", note = "@TheTool raid lead" },
            { name = "Hammer-Area52", class = "PALADIN", level = 70, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal", note = "Healer >Toolbox" },
            { name = "Wrench-Area52", class = "MAGE", level = 60, rank = 3, rankName = "Member",
                online = true, zone = "Dornogal", note = "Tailoring" },
        },
    }
end

-- Logs `playerName` in, lets the first scan finish, and opens the roster.
-- `canEdit` is whether the rank can edit public notes (true unless false).
local function login(channel, playerName, options)
    options = options or {}
    local world = fixtures.newEnvironment(options.profile or "Retail", {
        guild = options.guild or noteGuild(),
        playerName = playerName,
    })
    world.noteWrites = {}
    world.environment.CanEditPublicNote = function()
        return options.canEdit ~= false
    end
    world.environment.GuildRosterSetPublicNote = function(index, note)
        world.guild.members[index].note = note
        table.insert(world.noteWrites, world.guild.members[index].name)
    end
    if channel ~= nil then
        fixtures.joinChannel(channel, world)
    end
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    fixtures.fire(world, "PLAYER_ENTERING_WORLD")
    fixtures.fire(world, "GUILD_ROSTER_UPDATE")
    fixtures.runTimers(world)
    local controller = world.addon.rosterController
    controller.createWindow = function()
        local window = { shown = false }
        function window:IsShown() return self.shown end
        function window:Show() self.shown = true end
        function window:Hide() self.shown = false end
        function window:SetTitle() end
        function window:SetStatus() end
        function window:SetRows() return true end
        function window:SetConflicts() return true end
        function window:ShowPlayer() end
        function window:HidePlayer() end
        return window
    end
    test.assertTrue(controller:Toggle(), playerName .. " opens the roster")
    return world
end

local function noteOf(world, name)
    local index
    for index = 1, #world.guild.members do
        if world.guild.members[index].name == name then
            return world.guild.members[index].note
        end
    end
    return nil
end

local function partitionOf(world)
    local _, partition = world.addon.rosterController:QuietContext()
    return partition
end

-- Rescans, as the game's roster update after a write would make it.
local function rescan(world)
    world.addon.rosterController:Rescan()
    fixtures.runTimers(world)
end

test.test("composed: an officer's own edit rewrites the notes involved, read back with no conflict", function()
    local officer = login(nil, "Toolbox-Area52")
    local controller = officer.addon.rosterController
    local partition = partitionOf(officer)

    -- Wrench joins TheTool.
    test.assertTrue(controller:SetMainPlayer("wrench-area52", partition:GetCharacter("toolbox-area52").player))
    fixtures.runTimers(officer)

    test.assertEqual(">Toolbox Tailoring", noteOf(officer, "Wrench-Area52"))
    -- Already right: left alone.
    test.assertEqual("Healer >Toolbox", noteOf(officer, "Hammer-Area52"))
    test.assertEqual("@TheTool raid lead", noteOf(officer, "Toolbox-Area52"))
    test.assertEqual("Wrench-Area52", table.concat(officer.noteWrites, ","))
    test.assertContains(officer.messages[#officer.messages], "Guild notes: 1 updated.")

    -- Hammer is split off: its marker goes, its free text stays.
    test.assertTrue(controller:Detach("hammer-area52"))
    fixtures.runTimers(officer)
    test.assertEqual("Healer", noteOf(officer, "Hammer-Area52"))

    rescan(officer)
    partition = partitionOf(officer)
    test.assertEqual(0, #partition:GetConflicts())
    test.assertEqual("toolbox-area52",
        partition:GetPlayer(partition:GetCharacter("wrench-area52").player).main)
    test.assertEqual("hammer-area52",
        partition:GetPlayer(partition:GetCharacter("hammer-area52").player).main)
end)

test.test("composed: an officer's alias edit rewrites the main's note", function()
    local officer = login(nil, "Toolbox-Area52")

    test.assertTrue(officer.addon.rosterController:SetAlias("hammer-area52", "Tools"))
    fixtures.runTimers(officer)

    test.assertEqual("@Tools raid lead", noteOf(officer, "Toolbox-Area52"))
    rescan(officer)
    test.assertEqual(0, #partitionOf(officer):GetConflicts())
end)

test.test("composed: without permission, the edit still goes through and the officer is told", function()
    local officer = login(nil, "Toolbox-Area52", { canEdit = false })

    test.assertTrue(officer.addon.rosterController:Detach("hammer-area52"))
    fixtures.runTimers(officer)

    test.assertEqual(0, #officer.noteWrites)
    test.assertEqual("Healer >Toolbox", noteOf(officer, "Hammer-Area52"))
    local partition = partitionOf(officer)
    test.assertEqual("hammer-area52", partition:GetPlayer(partition:GetCharacter("hammer-area52").player).main)
    test.assertContains(officer.messages[#officer.messages], "can't edit public notes")
end)

test.test("composed: only the deciding officer writes; members and synced officers never do", function()
    local channel = fixtures.newChannel()
    local officer = login(channel, "Toolbox-Area52")
    -- Hammer is a member, but this one's rank could edit notes too.
    local hammer = login(channel, "Hammer-Area52")
    local wrench = login(channel, "Wrench-Area52")

    -- A member's own edit is only a suggestion: nothing is written.
    test.assertTrue(wrench.addon.rosterController:SetMainPlayer("wrench-area52",
        partitionOf(wrench):GetCharacter("toolbox-area52").player))
    fixtures.deliver(channel)
    fixtures.runTimers(wrench)
    test.assertEqual(0, #wrench.noteWrites)

    -- The officer approves: their add-on writes it.
    test.assertTrue(officer.addon.rosterController:AcceptConflict("wrench-area52", "suggested main"))
    fixtures.deliver(channel)
    fixtures.runTimers(officer)
    fixtures.runTimers(hammer)
    fixtures.runTimers(wrench)
    test.assertEqual(">Toolbox Tailoring", noteOf(officer, "Wrench-Area52"))
    test.assertEqual("Wrench-Area52", table.concat(officer.noteWrites, ","))
    test.assertEqual(0, #hammer.noteWrites)
    test.assertEqual(0, #wrench.noteWrites)

    -- An officer's edit received through sync writes nothing either.
    test.assertTrue(officer.addon.rosterController:Detach("hammer-area52"))
    fixtures.deliver(channel)
    fixtures.runTimers(hammer)
    fixtures.runTimers(wrench)
    test.assertEqual(0, #hammer.noteWrites)
    test.assertEqual(0, #wrench.noteWrites)
end)

test.test("composed Forever: markers use the first and last name", function()
    local officer = login(nil, "Tool Box", { profile = "Forever", guild = fixtures.snapshot(fixtures.GUILDS.Forever) })
    local controller = officer.addon.rosterController
    local partition = partitionOf(officer)
    local keys = {}
    partition:EachCharacter(function(key, character)
        keys[character.name] = key
    end)

    test.assertTrue(controller:SetMainPlayer(keys["Zélie Rune"], partition:GetCharacter(keys["Tool Box"]).player))
    fixtures.runTimers(officer)

    test.assertEqual(">Tool Box", noteOf(officer, "Zélie Rune"))
    rescan(officer)
    partition = partitionOf(officer)
    test.assertEqual(0, #partition:GetConflicts())
    test.assertEqual(keys["Tool Box"], partition:GetPlayer(partition:GetCharacter(keys["Zélie Rune"]).player).main)
end)

test.test("composed: an officer declaring their main writes >OwnName, read back as declared", function()
    local officer = login(nil, "Toolbox-Area52")

    test.assertTrue(officer.addon.rosterController:SetDeclared("toolbox-area52", true))
    fixtures.runTimers(officer)

    test.assertEqual(">Toolbox @TheTool raid lead", noteOf(officer, "Toolbox-Area52"))
    rescan(officer)
    local partition = partitionOf(officer)
    test.assertEqual(0, #partition:GetConflicts())
    test.assertTrue(partition:IsDeclared("toolbox-area52"))
end)
