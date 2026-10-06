local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")

local MANIFEST_FILES = {
    "Core/Identity.lua",
    "Adapters/ClientProfile.lua",
    "Adapters/WoW.lua",
    "Adapters/RosterWindow.lua",
    "Core/Persistence.lua",
    "Core/NameNormalizer.lua",
    "Core/NoteParser.lua",
    "Core/FellowshipStore.lua",
    "Core/ReconcileEngine.lua",
    "Core/RosterViewModel.lua",
    "Core/RosterController.lua",
    "Core/LibraryCheck.lua",
    "Core/CommandRouter.lua",
    "Core/Lifecycle.lua",
    "AsgardsGuildFellowship.lua",
}

local BUILDS = {
    {
        addonName = "AsgardsGuildFellowship",
        chatTag = "[Guild Fellowship]",
        displayName = "Asgard's Guild Fellowship",
        otherDatabaseName = "AsgardsGuildFellowshipDevDB",
        savedVariables = "AsgardsGuildFellowshipDB",
        slashAlias = "/asgardsfellowship",
        slashCommand = "/agf",
        slashKey = "AGF",
        -- The packager writes the release tag here when it builds a release.
        version = "@project-version@",
    },
    {
        addonName = "AsgardsGuildFellowshipDev",
        chatTag = "[Guild Fellowship (Dev)]",
        displayName = "Asgard's Guild Fellowship (Dev)",
        otherDatabaseName = "AsgardsGuildFellowshipDB",
        savedVariables = "AsgardsGuildFellowshipDevDB",
        slashAlias = "/asgardsfellowshipdev",
        slashCommand = "/agfdev",
        slashKey = "AGFDEV",
        version = "dev",
    },
}

-- Interface numbers start from the tithe add-on's values; confirm them in
-- game with `/dump (select(4, GetBuildInfo()))`.
local CLIENTS = {
    { name = "Forever", label = "WoW Forever", interface = "16000, 16001" },
    { name = "Retail", label = "WoW Retail", interface = "120100" },
}

local VARIANTS = {}
local buildIndex, clientIndex
for buildIndex = 1, #BUILDS do
    for clientIndex = 1, #CLIENTS do
        local variant = {}
        local key, value
        for key, value in pairs(BUILDS[buildIndex]) do
            variant[key] = value
        end
        variant.client = CLIENTS[clientIndex].name
        variant.clientLabel = CLIENTS[clientIndex].label
        variant.interface = CLIENTS[clientIndex].interface
        variant.toc = fixtures.manifestPath(variant.client, variant.addonName)
        table.insert(VARIANTS, variant)
    end
end

local function registerManifestTest(variant)
    test.test(variant.toc .. " declares its client, identity, and SavedVariables", function()
        local metadata = fixtures.manifestMetadata(variant.toc)

        test.assertEqual(variant.interface, metadata.Interface)
        test.assertEqual(variant.displayName, metadata.Title)
        test.assertEqual("FinalAsgard", metadata.Author)
        test.assertEqual(variant.version, metadata.Version)
        test.assertEqual(variant.savedVariables, metadata.SavedVariables)
        test.assertEqual(variant.client, metadata["X-Client"])
    end)
end

local function registerBootstrapTest(variant)
    test.test(variant.displayName .. " composes and bootstraps from " .. variant.toc, function()
        local otherDatabase = { sentinel = "other build" }
        local world = fixtures.newEnvironment(variant.client, { addonName = variant.addonName })
        local environment = world.environment
        environment[variant.otherDatabaseName] = otherDatabase

        local addon = fixtures.loadAddon(world)

        test.assertEqual(variant.slashCommand, addon.Identity.slashCommand)
        test.assertEqual(variant.slashAlias, addon.Identity.slashAlias)
        test.assertEqual(variant.savedVariables, addon.Identity.databaseName)
        test.assertContains(addon.Identity.chatPrefix, variant.chatTag)
        -- The lifecycle frame, plus the roster frame for GUILD_ROSTER_UPDATE.
        test.assertEqual(2, #world.frames)
        test.assertTrue(world.frames[2].registeredEvents.ADDON_LOADED)
        test.assertTrue(world.frames[2].registeredEvents.PLAYER_LOGIN)
        test.assertTrue(world.frames[1].registeredEvents.GUILD_ROSTER_UPDATE)

        fixtures.fire(world, "ADDON_LOADED", variant.addonName)
        -- Saved data waits for login.
        test.assertEqual(nil, world.database)
        world.loggedIn = true
        fixtures.fire(world, "PLAYER_LOGIN")

        test.assertEqual(1, world.database.schemaVersion)
        test.assertEqual("table", type(world.database.guilds))

        test.assertEqual(variant.slashCommand, environment["SLASH_" .. variant.slashKey .. "1"])
        test.assertEqual(variant.slashAlias, environment["SLASH_" .. variant.slashKey .. "2"])
        test.assertEqual(0, #world.messages)
        test.assertEqual(otherDatabase, environment[variant.otherDatabaseName])
        test.assertEqual("other build", otherDatabase.sentinel)

        environment.SlashCmdList[variant.slashKey]("help")
        test.assertContains(world.messages[1], variant.chatTag .. "|r Commands: " ..
            variant.slashCommand .. " help")
        test.assertContains(world.messages[1], variant.slashCommand .. " roster - show or hide the roster window")
        test.assertContains(world.messages[1], variant.slashCommand .. " rescan - rescan the guild roster now")
        test.assertContains(
            world.messages[2],
            "Version " .. variant.version .. " on " .. variant.clientLabel .. "."
        )
        test.assertContains(world.messages[3], "Libraries: all 6 present.")

        -- A bare slash command opens the roster. The fixtures' stand-in
        -- framework can't build windows, so it reports that instead of
        -- raising errors.
        environment.SlashCmdList[variant.slashKey]("")
        test.assertContains(world.messages[4], "The roster window can't open")
    end)
end

local index
for index = 1, #VARIANTS do
    registerManifestTest(VARIANTS[index])
    registerBootstrapTest(VARIANTS[index])
end

test.test("every manifest loads the same files in the same order", function()
    local variantIndex, fileIndex
    for variantIndex = 1, #VARIANTS do
        local files = fixtures.manifestFiles(VARIANTS[variantIndex].toc)
        test.assertEqual(#MANIFEST_FILES, #files, VARIANTS[variantIndex].toc .. " file count")
        for fileIndex = 1, #MANIFEST_FILES do
            test.assertEqual(
                MANIFEST_FILES[fileIndex],
                files[fileIndex],
                VARIANTS[variantIndex].toc .. " file " .. fileIndex
            )
        end
    end
end)

test.test("only the supported client manifests exist", function()
    if type(io.popen) ~= "function" then
        return
    end

    local expected = {}
    local variantIndex
    for variantIndex = 1, #VARIANTS do
        expected[VARIANTS[variantIndex].toc] = true
    end

    local listing = io.popen("ls")
    local found = 0
    local name
    for name in listing:lines() do
        if string.match(name, "%.toc$") then
            test.assertTrue(expected[name], "unexpected manifest " .. name)
            found = found + 1
        end
    end
    listing:close()
    test.assertEqual(#VARIANTS, found)
end)

-- The installer is verified by hand on Windows; this only keeps its names in
-- step with the dev build.
test.test("the dev installer links the dev folder for the dev manifests", function()
    local handle = assert(io.open("tools/Install-Dev.ps1", "r"))
    local source = handle:read("*a")
    handle:close()

    test.assertContains(source, '$addonFolderName = "AsgardsGuildFellowshipDev"')
    test.assertContains(source, 'Directory = "_classic_beta_"; Manifest = "AsgardsGuildFellowshipDev_Camelot.toc"')
    test.assertContains(source, 'Directory = "_retail_"; Manifest = "AsgardsGuildFellowshipDev_Mainline.toc"')
    test.assertContains(source, '[string]$Client = "Forever"')
    test.assertContains(source, '"Fetch-Libraries.ps1"')
    -- The libraries are fetched before the junction is created.
    local fetchAt = string.find(source, "& $fetchScript", 1, true)
    local linkAt = string.find(source, "New-Item -ItemType Junction", 1, true)
    test.assertTrue(fetchAt ~= nil, "installer runs the fetch script")
    test.assertTrue(linkAt ~= nil, "installer creates a junction")
    test.assertTrue(fetchAt < linkAt, "fetch runs before linking")
end)

test.test("an unknown add-on folder name is refused", function()
    local ok, failure = pcall(test.newAddonNamed, "AsgardsGuildFellowshipCopy")

    test.assertFalse(ok)
    test.assertContains(failure, "unsupported Asgard's Guild Fellowship add-on identity")
end)
