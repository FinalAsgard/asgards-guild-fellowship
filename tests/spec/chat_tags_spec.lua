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
    test.assertEqual("[TheTool] hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer-Area52"))
    test.assertEqual("[Anvil] hello", world.annotator:Annotate("CHAT_MSG_GUILD", "hello", "Tongs-Area52"))
end)

test.test("a Retail sender matches with or without a realm suffix", function()
    local world = retail()
    test.assertEqual("[TheTool] hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Hammer"))
    test.assertEqual("[TheTool] hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "hammer-Area52"))
    test.assertEqual("[TheTool] hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Saw-Stormrage"))
    test.assertEqual(nil, world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Saw"),
        "Saw without its realm is a different character")
end)

test.test("an accented sender is matched", function()
    local world = retail()
    test.assertTrue(world.service:SetAlias("élise-area52", "Lissy"))
    test.assertEqual("[Lissy] hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "ÉLISE-Area52"))
end)

test.test("Forever two-part sender names are matched", function()
    local world = setup(FOREVER, {
        { "Tool Box-Camelot", "@TheTool", 80 },
        { "Ham Mer-Camelot", ">Tool Box", 70 },
        { "Wren Ch-Camelot", "", 60 },
        { "Pli Ers-Camelot", ">Wren Ch", 50 },
    })
    test.assertEqual("[TheTool] hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Ham Mer"))
    test.assertEqual("[TheTool] hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Ham Mer-Camelot"))
    test.assertEqual("[Wren Ch] hi", world.annotator:Annotate("CHAT_MSG_GUILD", "hi", "Pli  Ers"))
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
