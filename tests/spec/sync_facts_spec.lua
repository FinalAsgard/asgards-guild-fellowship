local test = require("tests.test_helper")

-- Main-link facts: what an officer's edit says, and when one is applied.
local GUILD = { name = "Knights of Camelot", realm = "Area 52" }
local OFFICER = "toolbox-area52"
local OTHER_OFFICER = "gm-area52"
local MEMBER = "hammer-area52"
local NOW = 1790000000

local function newSetup(characters)
    local addon = test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/SyncFacts.lua"
    )
    local partition = addon.FellowshipStore.Create({ schemaVersion = 2, guilds = {} }):Partition(GUILD)
    local index
    for index = 1, #characters do
        partition:RecordCharacter(characters[index], { name = characters[index], level = 60 - index })
    end
    local officers = { [OFFICER] = true, [OTHER_OFFICER] = true }
    local facts = addon.SyncFacts.Create(partition, {
        isOfficer = function(key)
            return officers[key] == true
        end,
    })
    return { addon = addon, partition = partition, facts = facts, officers = officers }
end

local function mainOf(partition, key)
    return partition:GetPlayer(partition:GetCharacter(key).player).main
end

local function fact(character, main, at, by)
    return { kind = "main", character = character, main = main, at = at or NOW, by = by or OFFICER }
end

test.test("an officer's fact links an alt and records who set it and when", function()
    local setup = newSetup({ OFFICER, MEMBER, "toolbox2-area52" })

    local applied = setup.facts:ApplyAll({ fact(MEMBER, "toolbox2-area52") }, OFFICER)

    test.assertEqual(1, applied)
    test.assertEqual("toolbox2-area52", mainOf(setup.partition, MEMBER))
    test.assertEqual("sync", setup.partition:GetCharacter(MEMBER).source)
    local at, by = setup.partition:GetMainStamp(MEMBER)
    test.assertEqual(NOW, at)
    test.assertEqual(OFFICER, by)
end)

test.test("a fact from someone who isn't an officer is ignored", function()
    local setup = newSetup({ OFFICER, MEMBER, "wrench-area52" })

    local applied = setup.facts:ApplyAll({ fact("wrench-area52", MEMBER, NOW, MEMBER) }, MEMBER)

    test.assertEqual(0, applied)
    test.assertEqual("wrench-area52", mainOf(setup.partition, "wrench-area52"))
    test.assertEqual("not an officer", setup.facts:Refusal(fact("wrench-area52", MEMBER, NOW, MEMBER), MEMBER))
end)

test.test("a fact relayed by someone other than its author is not accepted yet", function()
    local setup = newSetup({ OFFICER, MEMBER, "wrench-area52" })

    test.assertEqual("relayed", setup.facts:Refusal(fact("wrench-area52", MEMBER), OTHER_OFFICER))
end)

test.test("the newest edit wins, and an equal time is settled the same way everywhere", function()
    local setup = newSetup({ OFFICER, OTHER_OFFICER, MEMBER, "wrench-area52" })

    setup.facts:ApplyAll({ fact(MEMBER, "wrench-area52", NOW + 10, OTHER_OFFICER) }, OTHER_OFFICER)
    -- Older: ignored.
    test.assertEqual(0, setup.facts:ApplyAll({ fact(MEMBER, OFFICER, NOW, OFFICER) }, OFFICER))
    test.assertEqual("wrench-area52", mainOf(setup.partition, MEMBER))
    -- Newer: applied.
    test.assertEqual(1, setup.facts:ApplyAll({ fact(MEMBER, OFFICER, NOW + 20, OFFICER) }, OFFICER))
    test.assertEqual(OFFICER, mainOf(setup.partition, MEMBER))
    -- Same second: the later author name wins, whichever arrives first.
    test.assertEqual(0, setup.facts:ApplyAll({ fact(MEMBER, "wrench-area52", NOW + 20, OTHER_OFFICER) }, OTHER_OFFICER))
    test.assertEqual(OFFICER, mainOf(setup.partition, MEMBER))
end)

test.test("a fact about a character this client doesn't know is ignored", function()
    local setup = newSetup({ OFFICER, MEMBER })

    test.assertEqual(0, setup.facts:ApplyAll({ fact(MEMBER, "stranger-area52") }, OFFICER))
    test.assertEqual(0, setup.facts:ApplyAll({ fact("stranger-area52", MEMBER) }, OFFICER))
    test.assertEqual(MEMBER, mainOf(setup.partition, MEMBER))
end)

test.test("malformed facts are ignored without errors", function()
    local setup = newSetup({ OFFICER, MEMBER })

    local applied = setup.facts:ApplyAll({
        "not a table",
        { kind = "alias", character = MEMBER, main = OFFICER, at = NOW, by = OFFICER },
        { kind = "main", character = MEMBER, main = OFFICER, at = "now", by = OFFICER },
        { kind = "main", character = MEMBER, main = OFFICER, at = 0, by = OFFICER },
        { kind = "main", character = MEMBER, at = NOW, by = OFFICER },
    }, OFFICER)

    test.assertEqual(0, applied)
    test.assertEqual(0, setup.facts:ApplyAll("nothing", OFFICER))
end)

test.test("a detach arrives as the character being its own main", function()
    local setup = newSetup({ OFFICER, MEMBER, "wrench-area52" })
    setup.partition:JoinPlayerOf(MEMBER, OFFICER, "manual")
    setup.partition:JoinPlayerOf("wrench-area52", OFFICER, "manual")

    setup.facts:ApplyAll({ fact(MEMBER, MEMBER) }, OFFICER)

    test.assertEqual(MEMBER, mainOf(setup.partition, MEMBER))
    test.assertEqual(1, #setup.partition:CharactersOf(setup.partition:GetCharacter(MEMBER).player))
    test.assertEqual(OFFICER, mainOf(setup.partition, "wrench-area52"))
end)

test.test("a new main arrives as every character of the player naming it, in any order", function()
    local orders = {
        { MEMBER, OFFICER, "wrench-area52" },
        { OFFICER, "wrench-area52", MEMBER },
        { "wrench-area52", MEMBER, OFFICER },
    }
    local orderIndex
    for orderIndex = 1, #orders do
        local setup = newSetup({ OFFICER, MEMBER, "wrench-area52" })
        setup.partition:JoinPlayerOf(MEMBER, OFFICER, "manual")
        setup.partition:JoinPlayerOf("wrench-area52", OFFICER, "manual")
        local batch = {}
        local index
        for index = 1, #orders[orderIndex] do
            table.insert(batch, fact(orders[orderIndex][index], MEMBER))
        end

        test.assertEqual(3, setup.facts:ApplyAll(batch, OFFICER))

        local player = setup.partition:GetCharacter(MEMBER).player
        test.assertEqual(MEMBER, setup.partition:GetPlayer(player).main, "order " .. orderIndex)
        test.assertEqual(3, #setup.partition:CharactersOf(player), "order " .. orderIndex)
    end
end)

test.test("stamping reports the current main links as the author's facts", function()
    local setup = newSetup({ OFFICER, MEMBER, "wrench-area52" })
    setup.partition:JoinPlayerOf(MEMBER, OFFICER, "manual")

    local facts = setup.facts:Stamp({ [MEMBER] = true, [OFFICER] = true, ["nobody-area52"] = true }, OFFICER, NOW)

    test.assertEqual(2, #facts)
    test.assertEqual(MEMBER, facts[1].character)
    test.assertEqual(OFFICER, facts[1].main)
    test.assertEqual(NOW, facts[1].at)
    test.assertEqual(OFFICER, facts[1].by)
    test.assertEqual(OFFICER, facts[2].character)
    test.assertEqual(OFFICER, facts[2].main)
    test.assertEqual(NOW, (setup.partition:GetMainStamp(OFFICER)))
    test.assertEqual(0, (setup.partition:GetMainStamp("wrench-area52")))
end)

test.test("a second edit within the same second is still newer", function()
    local setup = newSetup({ OFFICER, MEMBER, "wrench-area52" })
    local first = setup.facts:Stamp({ [MEMBER] = true }, OFFICER, NOW)
    local second = setup.facts:Stamp({ [MEMBER] = true }, OFFICER, NOW)

    test.assertEqual(NOW, first[1].at)
    test.assertEqual(NOW + 1, second[1].at)
end)

-- Alias facts -----------------------------------------------------------------

local function aliasFact(character, alias, at, by)
    return { kind = "alias", character = character, alias = alias, at = at or NOW, by = by or OFFICER }
end

local function aliasOf(partition, key)
    return partition:GetPlayer(partition:GetCharacter(key).player).alias
end

test.test("an officer's alias fact names the player and records who set it and when", function()
    local setup = newSetup({ OFFICER, MEMBER })

    test.assertEqual(1, setup.facts:ApplyAll({ aliasFact(MEMBER, "The Hammer") }, OFFICER))

    test.assertEqual("The Hammer", aliasOf(setup.partition, MEMBER))
    local player = setup.partition:GetPlayer(setup.partition:GetCharacter(MEMBER).player)
    test.assertEqual("sync", player.aliasSource)
    local at, by = setup.partition:GetAliasStamp(MEMBER)
    test.assertEqual(NOW, at)
    test.assertEqual(OFFICER, by)
end)

test.test("an empty alias fact clears the alias", function()
    local setup = newSetup({ OFFICER, MEMBER })
    setup.facts:ApplyAll({ aliasFact(MEMBER, "The Hammer") }, OFFICER)

    test.assertEqual(1, setup.facts:ApplyAll({ aliasFact(MEMBER, "", NOW + 5) }, OFFICER))

    test.assertEqual(nil, aliasOf(setup.partition, MEMBER))
    test.assertEqual(NOW + 5, (setup.partition:GetAliasStamp(MEMBER)))
end)

test.test("an alias fact from someone who isn't an officer is ignored", function()
    local setup = newSetup({ OFFICER, MEMBER })

    test.assertEqual(0, setup.facts:ApplyAll({ aliasFact(MEMBER, "Me", NOW, MEMBER) }, MEMBER))
    test.assertEqual(nil, aliasOf(setup.partition, MEMBER))
end)

test.test("when two officers set different aliases, the newest wins", function()
    local setup = newSetup({ OFFICER, OTHER_OFFICER, MEMBER })

    setup.facts:ApplyAll({ aliasFact(MEMBER, "Newer", NOW + 10, OTHER_OFFICER) }, OTHER_OFFICER)
    test.assertEqual(0, setup.facts:ApplyAll({ aliasFact(MEMBER, "Older", NOW, OFFICER) }, OFFICER))
    test.assertEqual("Newer", aliasOf(setup.partition, MEMBER))
    -- Same second: the later author name wins.
    test.assertEqual(1, setup.facts:ApplyAll({ aliasFact(MEMBER, "Tied", NOW + 10, OFFICER) }, OFFICER))
    test.assertEqual("Tied", aliasOf(setup.partition, MEMBER))
end)

test.test("an alias fact lands on the right player when this client still has an older main", function()
    local setup = newSetup({ OFFICER, MEMBER, "wrench-area52" })
    -- Here the officer is still the main; the sender already made Hammer main.
    setup.partition:JoinPlayerOf(MEMBER, OFFICER, "manual")

    test.assertEqual(1, setup.facts:ApplyAll({ aliasFact(MEMBER, "Tools") }, OFFICER))

    test.assertEqual("Tools", aliasOf(setup.partition, OFFICER))
    test.assertEqual(nil, aliasOf(setup.partition, "wrench-area52"))
end)

test.test("an alias that arrives after a main change stays with the player", function()
    local setup = newSetup({ OFFICER, MEMBER })
    setup.partition:JoinPlayerOf(MEMBER, OFFICER, "manual")

    setup.facts:ApplyAll({ fact(OFFICER, MEMBER), fact(MEMBER, MEMBER) }, OFFICER)
    setup.facts:ApplyAll({ aliasFact(MEMBER, "Tools", NOW + 1) }, OFFICER)

    test.assertEqual(MEMBER, mainOf(setup.partition, OFFICER))
    test.assertEqual("Tools", aliasOf(setup.partition, OFFICER))
end)

test.test("malformed alias facts are ignored", function()
    local setup = newSetup({ OFFICER, MEMBER })

    test.assertEqual(0, setup.facts:ApplyAll({
        { kind = "alias", character = MEMBER, at = NOW, by = OFFICER },
        { kind = "alias", character = MEMBER, alias = 7, at = NOW, by = OFFICER },
        aliasFact(MEMBER, string.rep("x", 49)),
        aliasFact("stranger-area52", "Nobody"),
    }, OFFICER))
    test.assertEqual(nil, aliasOf(setup.partition, MEMBER))
end)

test.test("stamping an alias reports it by the player's main, empty when there is none", function()
    local setup = newSetup({ OFFICER, MEMBER })
    setup.partition:JoinPlayerOf(MEMBER, OFFICER, "manual")

    local cleared = setup.facts:StampAlias(MEMBER, OFFICER, NOW)
    test.assertEqual("alias", cleared.kind)
    test.assertEqual(OFFICER, cleared.character)
    test.assertEqual("", cleared.alias)
    test.assertEqual(NOW, cleared.at)
    test.assertEqual(OFFICER, cleared.by)

    setup.partition:SetAlias(setup.partition:GetCharacter(MEMBER).player, "Tools", "manual")
    local set = setup.facts:StampAlias(MEMBER, OFFICER, NOW)
    test.assertEqual("Tools", set.alias)
    test.assertEqual(NOW + 1, set.at)
    test.assertEqual(nil, setup.facts:StampAlias("nobody-area52", OFFICER, NOW))
end)

-- Upgrading from before sync --------------------------------------------------

test.test("upgrading stamps only unstamped manual links and aliases as the officer's", function()
    local setup = newSetup({ OFFICER, MEMBER, "wrench-area52", "anvil-area52" })
    -- Before sync: Hammer linked by hand, Anvil detached by hand, an alias
    -- cleared by hand, and Wrench seeded from its note.
    setup.partition:JoinPlayerOf(MEMBER, OFFICER, "manual")
    setup.partition:MoveToNewPlayer("anvil-area52", "manual")
    setup.partition:ClearAlias(setup.partition:GetCharacter("anvil-area52").player, "manual")
    setup.partition:SetAlias(setup.partition:GetCharacter("wrench-area52").player, "Sparky", "note")
    setup.partition:GetCharacter("wrench-area52").source = "note"
    -- Already stamped since sync shipped: left alone.
    setup.partition:SetAlias(setup.partition:GetCharacter(OFFICER).player, "Tools", "manual")
    setup.partition:SetAliasStamp(OFFICER, NOW - 50, OTHER_OFFICER)

    local facts = setup.facts:StampLegacy(OFFICER, NOW)

    test.assertEqual(3, #facts)
    test.assertEqual("anvil-area52", facts[1].character)
    test.assertEqual("anvil-area52", facts[1].main)
    test.assertEqual(MEMBER, facts[2].character)
    test.assertEqual(OFFICER, facts[2].main)
    test.assertEqual("alias", facts[3].kind)
    test.assertEqual("anvil-area52", facts[3].character)
    test.assertEqual("", facts[3].alias)
    local index
    for index = 1, #facts do
        test.assertEqual(NOW, facts[index].at)
        test.assertEqual(OFFICER, facts[index].by)
    end
    test.assertEqual(0, (setup.partition:GetMainStamp("wrench-area52")))
    test.assertEqual(0, (setup.partition:GetAliasStamp("wrench-area52")))
    local at, by = setup.partition:GetAliasStamp(OFFICER)
    test.assertEqual(NOW - 50, at)
    test.assertEqual(OTHER_OFFICER, by)

    test.assertEqual(0, #setup.facts:StampLegacy(OFFICER, NOW + 60))
end)
