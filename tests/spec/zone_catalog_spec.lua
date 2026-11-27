local test = require("tests.test_helper")

-- ZoneCatalog ---------------------------------------------------------------

local function newCatalogModule()
    return test.newAddon("Core/ZoneCatalog.lua").ZoneCatalog
end

local SAMPLE = {
    { mapId = 1431, name = "Duskwood", minLevel = 18, maxLevel = 30 },
    { mapId = 1429, name = "Elwynn Forest", minLevel = 1, maxLevel = 10 },
    { mapId = 1436, name = "Westfall", minLevel = 9, maxLevel = 18 },
    { mapId = 1434, name = "Stranglethorn Vale", minLevel = 30, maxLevel = 45 },
    { mapId = 1453, name = "Stormwind City" },
}

local function names(list)
    local result = {}
    local index
    for index = 1, #list do
        result[index] = list[index].name
    end
    return table.concat(result, ", ")
end

test.test("zone catalog: the zones a level fits, then the rest, each by name", function()
    local catalog = newCatalogModule().Create(SAMPLE)

    local fitting, others = catalog:Search("", 18)
    test.assertEqual("Duskwood, Westfall", names(fitting))
    -- A zone without a range is among the others.
    test.assertEqual("Elwynn Forest, Stormwind City, Stranglethorn Vale", names(others))
    test.assertEqual(1431, fitting[1].mapId)
    test.assertEqual(1431, fitting[1].id)
end)

test.test("zone catalog: search ignores case and keeps the split", function()
    local catalog = newCatalogModule().Create(SAMPLE)

    local fitting, others = catalog:Search("  WEST ", 12)
    test.assertEqual("Westfall", names(fitting))
    test.assertEqual("", names(others))
    fitting, others = catalog:Search("st", 12)
    test.assertEqual("Westfall", names(fitting))
    test.assertEqual("Elwynn Forest, Stormwind City, Stranglethorn Vale", names(others))
    fitting, others = catalog:Search("nowhere", 12)
    test.assertEqual(0, #fitting + #others)
end)

test.test("zone catalog: the current zone joins a list that lacks it; unusable entries are left out", function()
    local ZoneCatalog = newCatalogModule()

    local catalog = ZoneCatalog.Create({}, { name = "Ironforge" })
    test.assertEqual(1, #catalog.zones)
    test.assertEqual("Ironforge", catalog:Named("Ironforge").id)
    local fitting, others = catalog:Search("", 60)
    test.assertEqual(0, #fitting)
    test.assertEqual("Ironforge", names(others))

    -- A listed zone isn't added twice; the list's entry wins.
    catalog = ZoneCatalog.Create(SAMPLE, { name = "Duskwood", minLevel = 99, maxLevel = 99 })
    test.assertEqual(5, #catalog.zones)
    test.assertEqual(18, catalog:Named("Duskwood").minLevel)

    catalog = ZoneCatalog.Create({ { name = "" }, "Duskwood", { name = "Bad", minLevel = 30, maxLevel = 20 },
        { name = "Half", minLevel = 5 } })
    test.assertEqual("Bad, Half", names(catalog.zones))
    test.assertEqual(nil, catalog:Named("Bad").minLevel)
    test.assertEqual(nil, catalog:Named("Half").minLevel)

    -- Nothing at all: an empty catalog.
    catalog = ZoneCatalog.Create(nil, nil)
    test.assertEqual(0, #catalog.zones)
    fitting, others = catalog:Search("", 10)
    test.assertEqual(0, #fitting + #others)
end)
