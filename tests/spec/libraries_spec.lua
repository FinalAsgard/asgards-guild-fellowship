local test = require("tests.test_helper")
local fixtures = require("tests.client_fixtures")
local LibraryList = require("tools.library_list")

local MANIFESTS = {
    "AsgardsGuildFellowship_Camelot.toc",
    "AsgardsGuildFellowship_Mainline.toc",
    "AsgardsGuildFellowshipDev_Camelot.toc",
    "AsgardsGuildFellowshipDev_Mainline.toc",
}

local function listEntries()
    local entries, listError = LibraryList.Parse()
    test.assertTrue(entries ~= nil, "library list parses: " .. tostring(listError))
    return entries
end

local function copyPkgmeta(pkgmeta)
    return fixtures.snapshot(pkgmeta)
end

-- Library list -------------------------------------------------------------

test.test("library list pins the required libraries in load order", function()
    local entries = listEntries()
    local expected = {
        "LibStub",
        "CallbackHandler-1.0",
        "LibDataBroker-1.1",
        "LibDBIcon-1.0",
        "LibSharedMedia-3.0",
        "DetailsFramework-1.0",
    }

    test.assertEqual(#expected, #entries, "library count")
    local index
    for index = 1, #expected do
        test.assertEqual(expected[index], entries[index].major, "library " .. index)
        test.assertTrue(entries[index].tag ~= "", entries[index].name .. " is pinned")
        test.assertEqual("Libs/", string.sub(entries[index].target, 1, 5))
    end
end)

test.test(".pkgmeta externals match the library list", function()
    local pkgmeta = assert(LibraryList.ParsePkgmeta())
    local problems = LibraryList.Compare(listEntries(), pkgmeta)

    test.assertEqual(0, #problems, table.concat(problems, "; "))
end)

test.test("library consistency check reports every kind of drift", function()
    local entries = listEntries()
    local pkgmeta = copyPkgmeta(assert(LibraryList.ParsePkgmeta()))

    pkgmeta.externals["Libs/DetailsFramework"].tag = "v1.0.0"
    pkgmeta.externals["Libs/LibStub"].url = "https://example.invalid/libstub"
    pkgmeta.externals["Libs/LibDBIcon-1.0"].type = nil
    pkgmeta.externals["Libs/LibDataBroker-1.1"] = nil
    pkgmeta.externals["Libs/Extra"] = { path = "Libs/Extra", url = "https://example.invalid/extra" }
    table.insert(pkgmeta.externalOrder, "Libs/Extra")

    local problems = table.concat(LibraryList.Compare(entries, pkgmeta), "\n")

    test.assertContains(problems, "Libs/DetailsFramework tag is v1.0.0")
    test.assertContains(problems, "Libs/LibStub url is https://example.invalid/libstub")
    test.assertContains(problems, "Libs/LibDBIcon-1.0 type is git in .pkgmeta but svn")
    test.assertContains(problems, "Libs/LibDataBroker-1.1 is pinned in the list but missing from .pkgmeta")
    test.assertContains(problems, "Libs/Extra is in .pkgmeta but not in the library list")
end)

test.test(".pkgmeta names the package and ignores development-only files", function()
    local pkgmeta = assert(LibraryList.ParsePkgmeta())
    local ignored = {}
    local index
    for index = 1, #pkgmeta.ignore do
        ignored[pkgmeta.ignore[index]] = true
    end

    test.assertEqual("AsgardsGuildFellowship", pkgmeta.packageAs)
    local required = {
        ".github",
        "ai",
        "AsgardsGuildFellowshipDev_Camelot.toc",
        "AsgardsGuildFellowshipDev_Mainline.toc",
        "docs",
        "tests",
        "tools",
    }
    for index = 1, #required do
        test.assertTrue(ignored[required[index]], required[index] .. " is ignored")
    end
end)

local function readFile(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    return text
end

test.test("the release changelog is declared to the packager and never committed", function()
    local pkgmeta = readFile(".pkgmeta")
    test.assertTrue(string.find(pkgmeta, "\nmanual%-changelog:\n  filename: CHANGELOG%.md\n") ~= nil,
        ".pkgmeta declares CHANGELOG.md as the manual changelog")
    local ignored = false
    for line in string.gmatch(readFile(".gitignore"), "[^\n]+") do
        ignored = ignored or line == "CHANGELOG.md"
    end
    test.assertTrue(ignored, "CHANGELOG.md is git-ignored")
end)

test.test("the package ships an MIT license for FinalAsgard", function()
    local license = readFile("LICENSE")
    test.assertTrue(string.find(license, "^MIT License") ~= nil, "LICENSE is the MIT license")
    test.assertTrue(string.find(license, "Copyright %(c%) %d+ FinalAsgard") ~= nil, "LICENSE names FinalAsgard")
end)

test.test("every manifest loads the libraries first, in list order", function()
    local libraryLines = LibraryList.ManifestLines(listEntries())
    local manifestIndex, lineIndex
    for manifestIndex = 1, #MANIFESTS do
        local lines = fixtures.manifestLines(MANIFESTS[manifestIndex])
        for lineIndex = 1, #libraryLines do
            test.assertEqual(libraryLines[lineIndex], lines[lineIndex], MANIFESTS[manifestIndex] .. " line " .. lineIndex)
        end
        for lineIndex = #libraryLines + 1, #lines do
            test.assertTrue(
                string.sub(lines[lineIndex], 1, 5) ~= "Libs/",
                MANIFESTS[manifestIndex] .. " loads a library after add-on code"
            )
        end
    end
end)

test.test("the load-time check requires exactly the listed libraries", function()
    local addon = test.newAddon("Core/LibraryCheck.lua")
    local entries = listEntries()
    local required = addon.LibraryCheck.REQUIRED

    test.assertEqual(#entries, #required, "required library count")
    local index
    for index = 1, #entries do
        test.assertEqual(entries[index].major, required[index].major)
        test.assertEqual(entries[index].name, required[index].name)
    end
end)

test.test("fixture library stand-ins cover every listed library", function()
    local entries = listEntries()
    local index
    test.assertEqual(#entries - 1, #fixtures.LIBRARY_MAJORS)
    for index = 2, #entries do
        test.assertEqual(entries[index].major, fixtures.LIBRARY_MAJORS[index - 1])
    end
end)

-- Load-time check ----------------------------------------------------------

local function start(profile, options)
    local world = fixtures.newEnvironment(profile, options)
    fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", world.addonName)
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    return world
end

local function registerProfileTests(profile)
    test.test(profile .. " with every library present prints nothing and help says so", function()
        local world = start(profile)

        test.assertEqual(0, #world.messages)
        fixtures.slash(world, "help")
        test.assertContains(world.messages[#world.messages], "Libraries: all 6 present.")
    end)

    test.test(profile .. " names missing libraries once and keeps help working", function()
        local world = start(profile, { missingLibraries = { "LibDBIcon-1.0", "LibDataBroker-1.1" } })
        fixtures.fire(world, "PLAYER_ENTERING_WORLD")

        test.assertEqual(1, #world.messages)
        test.assertContains(world.messages[1], "Missing libraries: LibDataBroker-1.1, LibDBIcon-1.0.")
        test.assertContains(world.messages[1], "tools/Fetch-Libraries.ps1")

        fixtures.slash(world, "help")
        local summary = world.messages[#world.messages]
        test.assertContains(summary, "Libraries present: LibStub, CallbackHandler-1.0, LibSharedMedia-3.0, Details! Framework.")
        test.assertContains(summary, "Missing: LibDataBroker-1.1, LibDBIcon-1.0.")
        -- Saved data is unaffected by missing libraries.
        test.assertEqual(1, world.database.schemaVersion)
    end)

    test.test(profile .. " reports a half-loaded Details! Framework as missing", function()
        local world = start(profile, { frameworkFailed = true })

        test.assertEqual(1, #world.messages)
        test.assertContains(world.messages[1], "Missing libraries: Details! Framework.")
    end)

    test.test(profile .. " without LibStub reports every library missing without errors", function()
        local world = start(profile, { libStub = false })

        test.assertEqual(1, #world.messages)
        test.assertContains(
            world.messages[1],
            "Missing libraries: LibStub, CallbackHandler-1.0, LibDataBroker-1.1, LibDBIcon-1.0, " ..
                "LibSharedMedia-3.0, Details! Framework."
        )
        fixtures.slash(world, "help")
        test.assertContains(world.messages[#world.messages], "Libraries present: none.")
    end)
end

local profileIndex
for profileIndex = 1, #fixtures.PROFILES do
    registerProfileTests(fixtures.PROFILES[profileIndex])
end

test.test("a LibStub that raises is treated as missing libraries", function()
    local addon = test.newAddon("Adapters/ClientProfile.lua", "Adapters/WoW.lua", "Core/LibraryCheck.lua")
    local client = addon.Compatibility.Create({
        LibStub = {
            GetLibrary = function()
                error("broken registry")
            end,
        },
    })
    local check = addon.LibraryCheck.Create(client)

    local present, missing = check:Run()

    test.assertEqual(1, #present)
    test.assertEqual("LibStub", present[1])
    test.assertEqual(5, #missing)
end)
