local test = require("tests.test_helper")

local RETAIL = { twoPartNames = false, homeRealm = "Area52" }
local FOREVER = { twoPartNames = true, homeRealm = "Camelot" }
local START = 1790000000

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/NoteParser.lua",
        "Core/FellowshipStore.lua",
        "Core/ReconcileEngine.lua",
        "Core/PlayerService.lua",
        "Core/ChatAnnotator.lua"
    )
end

-- A guild scanned from `entries` ({ name, note, level }), with a service
-- and an annotator over its partition.
local function setup(rules, entries)
    local addon = load()
    local partition = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
        :Partition({ name = "Knights", realm = rules.homeRealm })
    local normalizer = addon.NameNormalizer.Create(rules)
    local world = { addon = addon, partition = partition, normalizer = normalizer }

    function world.scan(members, mode, now)
        local byKey = {}
        local index
        for index = 1, #members do
            byKey[normalizer:Key(members[index][1])] = {
                name = members[index][1], note = members[index][2] or "", level = members[index][3] or 60,
            }
        end
        addon.ReconcileEngine.Apply(partition, addon.ReconcileEngine.Plan({
            partition = partition, members = byKey, normalizer = normalizer,
            rules = rules, mode = mode, now = now or START,
        }))
    end

    world.service = addon.PlayerService.Create(partition, { normalizer = normalizer })
    world.annotator = addon.ChatAnnotator.Create({
        context = function()
            return partition, normalizer
        end,
    })
    world.scan(entries, "initial")
    return world
end

-- Toolbox (alias TheTool) with alts Hammer and Wrench; Anvil (no alias)
-- with alts Tongs and Pliers; Bolt, Élise, and Nail on their own; Saw from
-- another realm as an alt of Toolbox; Screw as an alt of Nail-Stormrage.
local RETAIL_GUILD = {
    { "Toolbox-Area52", "@TheTool", 80 },
    { "Hammer-Area52", ">Toolbox", 70 },
    { "Wrench-Area52", ">Toolbox", 60 },
    { "Anvil-Area52", "", 80 },
    { "Tongs-Area52", ">Anvil", 70 },
    { "Pliers-Area52", ">Anvil", 60 },
    { "Bolt-Area52", "", 80 },
    { "Élise-Area52", "@ÉLISE", 80 },
    { "Saw-Stormrage", ">Toolbox", 50 },
    { "Nail-Stormrage", "", 80 },
    { "Screw-Area52", ">Nail-Stormrage", 40 },
}

local function retail()
    return setup(RETAIL, RETAIL_GUILD)
end

local function assertTag(expectedText, expectedKind, tag, message)
    if expectedText == nil then
        test.assertEqual(nil, tag, message)
        return
    end
    test.assertTrue(type(tag) == "table", (message or "tag") .. " exists")
    test.assertEqual(expectedText, tag.text, message)
    test.assertEqual(expectedKind, tag.kind, message)
end

-- How chat shows a tag: green for an alias, light blue for a main's name.
local function alias(text)
    return "|cff7fff7f[" .. text .. "]|r "
end

local function main(text)
    return "|cff7fd4ff[" .. text .. "]|r "
end

-- The tag rule -----------------------------------------------------------------

test.test("an alt of a player with an alias is tagged with the alias", function()
    local world = retail()
    assertTag("TheTool", "alias", world.service:ChatTag("hammer-area52"))
end)

test.test("a main with an alias is tagged with the alias", function()
    local world = retail()
    assertTag("TheTool", "alias", world.service:ChatTag("toolbox-area52"))
end)

test.test("an alt of a player without an alias is tagged with the main's name", function()
    local world = retail()
    assertTag("Anvil", "main", world.service:ChatTag("tongs-area52"))
end)

test.test("a main without an alias gets no tag", function()
    local world = retail()
    assertTag(nil, nil, world.service:ChatTag("anvil-area52"))
    assertTag(nil, nil, world.service:ChatTag("bolt-area52"))
end)

test.test("a tag that repeats the speaker's own name is dropped, ignoring case", function()
    local world = retail()
    test.assertTrue(world.service:SetAlias("bolt-area52", "BOLT"))
    assertTag(nil, nil, world.service:ChatTag("bolt-area52"))
end)

test.test("the own-name comparison folds accented letters too", function()
    local world = retail()
    assertTag(nil, nil, world.service:ChatTag("élise-area52"))
end)

test.test("a character the database doesn't know gets no tag", function()
    local world = retail()
    assertTag(nil, nil, world.service:ChatTag("stranger-area52"))
end)

test.test("when the original main leaves, alts are tagged with the acting main", function()
    local world = retail()
    local remaining = {}
    local index
    for index = 1, #RETAIL_GUILD do
        if RETAIL_GUILD[index][1] ~= "Anvil-Area52" then
            table.insert(remaining, RETAIL_GUILD[index])
        end
    end
    world.scan(remaining, "full", START + 86400)
    -- Tongs is the highest level in-guild alt, so it becomes the acting main.
    assertTag("Tongs", "main", world.service:ChatTag("pliers-area52"))
    assertTag(nil, nil, world.service:ChatTag("tongs-area52"))
end)

test.test("an alias set in the roster shows in the next lookup", function()
    local world = retail()
    assertTag("Anvil", "main", world.service:ChatTag("tongs-area52"))
    test.assertTrue(world.service:SetAlias("tongs-area52", "Smith"))
    assertTag("Smith", "alias", world.service:ChatTag("tongs-area52"))
    assertTag("Smith", "alias", world.service:ChatTag("anvil-area52"))
    test.assertTrue(world.service:SetAlias("tongs-area52", ""))
    assertTag("Anvil", "main", world.service:ChatTag("tongs-area52"))
end)

test.test("a main on another realm is named with its realm", function()
    local world = retail()
    assertTag("Nail-Stormrage", "main", world.service:ChatTag("screw-area52"))
end)

-- The annotator ----------------------------------------------------------------

test.test("guild chat from an alt gets the tag in front of the message", function()
    local world = retail()
    test.assertEqual(alias("TheTool") .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
    test.assertEqual(main("Anvil") .. "hello", world.annotator:Annotate("CHAT_MSG_GUILD", "hello", "Tongs-Area52"))
end)

test.test("a Retail sender matches with or without a realm suffix", function()
    local world = retail()
    test.assertEqual(alias("TheTool") .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer"))
    test.assertEqual(alias("TheTool") .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "hammer-Area52"))
    test.assertEqual(alias("TheTool") .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Saw-Stormrage"))
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Saw"),
        "Saw without its realm is a different character")
end)

test.test("an accented sender is matched", function()
    local world = retail()
    test.assertTrue(world.service:SetAlias("élise-area52", "Lissy"))
    test.assertEqual(alias("Lissy") .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "ÉLISE-Area52"))
end)

test.test("Forever two-part sender names are matched", function()
    local world = setup(FOREVER, {
        { "Tool Box-Camelot", "@TheTool", 80 },
        { "Ham Mer-Camelot", ">Tool Box", 70 },
        { "Wren Ch-Camelot", "", 60 },
        { "Pli Ers-Camelot", ">Wren Ch", 50 },
    })
    test.assertEqual(alias("TheTool") .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Ham Mer"))
    test.assertEqual(alias("TheTool") .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Ham Mer-Camelot"))
    test.assertEqual(main("Wren Ch") .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Pli  Ers"))
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Wren Ch"))
end)

test.test("a speaker with nothing new to show leaves the message unchanged", function()
    local world = retail()
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Anvil-Area52"))
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Stranger-Area52"))
end)

test.test("other chat events are left unchanged", function()
    local world = retail()
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_SAY", "hi", "Hammer-Area52"))
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_WHISPER", "hi", "Hammer-Area52"))
end)

test.test("without a guild context, chat is left unchanged", function()
    local addon = load()
    local annotator = addon.ChatAnnotator.Create({
        context = function()
            return nil
        end,
    })
    test.assertEqual(nil, annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
end)

test.test("a failing context or bad arguments never raise", function()
    local addon = load()
    local annotator = addon.ChatAnnotator.Create({
        context = function()
            error("guild info exploded")
        end,
    })
    test.assertEqual(nil, annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))

    local world = retail()
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD", nil, "Hammer-Area52"))
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD", "hi", nil))
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD", "hi", ""))
    test.assertEqual(nil, world.annotator:Annotate(nil, "hi", "Hammer-Area52"))
end)

-- How tags look --------------------------------------------------------------

test.test("alias tags are green and main-name tags light blue, each closed", function()
    local world = retail()
    test.assertEqual("|cff7fff7f[TheTool]|r hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
    test.assertEqual("|cff7fd4ff[Anvil]|r hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Tongs-Area52"))
end)

test.test("a | in an alias is shown literally, not read as an escape code", function()
    local world = retail()
    test.assertTrue(world.service:SetAlias("tongs-area52", "Smith|cffff0000Evil|r"))
    test.assertEqual("|cff7fff7f[Smith||cffff0000Evil||r]|r hi",
        world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Tongs-Area52"))
end)

test.test("a long multi-word alias is shown in full", function()
    local world = retail()
    local long = "The Most Reliable Tool In The Whole Box Of Tools"
    test.assertEqual(48, #long)
    test.assertTrue(world.service:SetAlias("tongs-area52", long))
    test.assertEqual(alias(long) .. "hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Pliers-Area52"))
end)

-- Officer chat and achievements ------------------------------------------------

local ACHIEVEMENT = "%s has earned the achievement |cffffff00|Hachievement:6:0|h[Level 10]|h|r!"

test.test("officer chat is tagged like guild chat", function()
    local world = retail()
    test.assertEqual(alias("TheTool") .. "hi", world.annotator:Annotate("CHAT_MSG_OFFICER", "hi", "Hammer-Area52"))
    test.assertEqual(main("Anvil") .. "hi", world.annotator:Annotate("CHAT_MSG_OFFICER", "hi", "Tongs-Area52"))
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_OFFICER", "hi", "Anvil-Area52"))
end)

test.test("an achievement gets the tag right after the name placeholder", function()
    local world = retail()
    test.assertEqual(
        "%s |cff7fff7f[TheTool]|r has earned the achievement |cffffff00|Hachievement:6:0|h[Level 10]|h|r!",
        world.annotator:Annotate("CHAT_MSG_GUILD_ACHIEVEMENT", ACHIEVEMENT, "Hammer-Area52"))
    test.assertEqual(
        "%s |cff7fd4ff[Anvil]|r has earned the achievement |cffffff00|Hachievement:6:0|h[Level 10]|h|r!",
        world.annotator:Annotate("CHAT_MSG_GUILD_ACHIEVEMENT", ACHIEVEMENT, "Tongs-Area52"))
end)

test.test("only the first placeholder of an achievement gets the tag", function()
    local world = retail()
    test.assertEqual("%s |cff7fff7f[TheTool]|r and %s",
        world.annotator:Annotate("CHAT_MSG_GUILD_ACHIEVEMENT", "%s and %s", "Hammer-Area52"))
end)

test.test("an achievement without a name placeholder is left unchanged", function()
    local world = retail()
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD_ACHIEVEMENT",
        "Hammer has earned the achievement [Level 10]!", "Hammer-Area52"))
end)

test.test("an achievement by a speaker with nothing new to show is left unchanged", function()
    local world = retail()
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD_ACHIEVEMENT", ACHIEVEMENT, "Anvil-Area52"))
end)

test.test("tags are added to guild, officer, and achievement events only", function()
    local world = retail()
    local expected = { CHAT_MSG_GUILD = true, CHAT_MSG_OFFICER = true, CHAT_MSG_GUILD_ACHIEVEMENT = true }
    local events = world.addon.ChatAnnotator.EVENTS
    test.assertEqual(3, #events)
    local index
    for index = 1, #events do
        test.assertTrue(expected[events[index]], events[index] .. " is expected")
    end
    local other = { "CHAT_MSG_SAY", "CHAT_MSG_PARTY", "CHAT_MSG_RAID", "CHAT_MSG_ACHIEVEMENT", "CHAT_MSG_CHANNEL" }
    for index = 1, #other do
        test.assertEqual(nil, world.annotator:Annotate(other[index], "%s hi", "Hammer-Area52"), other[index])
    end
end)

-- Values the client hides from add-ons ---------------------------------------

-- An annotator over `world` whose client hides the values in `secrets`, and
-- that counts how often it reads the guild context.
local function hiding(world, secrets)
    local annotator = { contextReads = 0 }
    annotator.annotator = world.addon.ChatAnnotator.Create({
        context = function()
            annotator.contextReads = annotator.contextReads + 1
            return world.partition, world.normalizer
        end,
        isSecret = function(value)
            return secrets[value] == true
        end,
    })
    return annotator
end

test.test("a hidden message is left unchanged without being looked at", function()
    local world = retail()
    local probe = hiding(world, { ["hi"] = true, ["%s has earned"] = true })
    test.assertEqual(nil, probe.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
    test.assertEqual(nil, probe.annotator:Annotate("CHAT_MSG_GUILD_ACHIEVEMENT", "%s has earned", "Hammer-Area52"))
    test.assertEqual(0, probe.contextReads, "no lookup for a hidden message")
end)

test.test("a hidden sender is left unchanged without being normalized", function()
    local world = retail()
    local probe = hiding(world, { ["Hammer-Area52"] = true })
    test.assertEqual(nil, probe.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
    test.assertEqual(nil, probe.annotator:Annotate("CHAT_MSG_OFFICER", "hi", "Hammer-Area52"))
    test.assertEqual(0, probe.contextReads, "no lookup for a hidden sender")
end)

test.test("once nothing is hidden, tags come back", function()
    local world = retail()
    local secrets = { ["Hammer-Area52"] = true }
    local probe = hiding(world, secrets)
    test.assertEqual(nil, probe.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
    secrets["Hammer-Area52"] = nil
    test.assertEqual(alias("TheTool") .. "hi", probe.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
end)

test.test("without a secret check, chat is tagged normally", function()
    local world = retail()
    local annotator = world.addon.ChatAnnotator.Create({
        context = function()
            return world.partition, world.normalizer
        end,
    })
    test.assertEqual(alias("TheTool") .. "hi", annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
end)

test.test("a secret check that errors leaves the line unchanged and never raises", function()
    local world = retail()
    local annotator = world.addon.ChatAnnotator.Create({
        context = function()
            return world.partition, world.normalizer
        end,
        isSecret = function()
            error("secret check exploded")
        end,
    })
    test.assertEqual(nil, annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
end)
