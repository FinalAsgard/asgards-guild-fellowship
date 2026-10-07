local test = require("tests.test_helper")

local function normalizer(rules)
    local addon = test.newAddon("Core/NameNormalizer.lua")
    return addon.NameNormalizer.Create(rules)
end

local FOREVER = { twoPartNames = true, homeRealm = "Camelot" }
local RETAIL = { twoPartNames = false, homeRealm = "Area 52" }

local KEY_CASES = {
    { rules = FOREVER, input = "Tool Box-Camelot", key = "tool box-camelot", why = "Forever two-part name" },
    { rules = FOREVER, input = "tool box", key = "tool box-camelot", why = "missing realm uses the home realm" },
    { rules = FOREVER, input = "  TOOL   Box ", key = "tool box-camelot", why = "whitespace collapses to one space" },
    { rules = FOREVER, input = "Zélie Rune", key = "zélie rune-camelot", why = "accented letters keep their form" },
    { rules = FOREVER, input = "ZÉLIE RUNE", key = "zélie rune-camelot", why = "accented capitals fold" },
    { rules = RETAIL, input = "Toolbox-Area52", key = "toolbox-area52", why = "Retail single name" },
    { rules = RETAIL, input = "toolbox", key = "toolbox-area52", why = "home realm loses its spaces" },
    { rules = RETAIL, input = "Visitor-Stormrage", key = "visitor-stormrage", why = "other realms are kept" },
    { rules = RETAIL, input = "Tool box", key = "toolbox-area52", why = "Retail names have no spaces" },
}

local index
for index = 1, #KEY_CASES do
    local case = KEY_CASES[index]
    test.test("name key: " .. case.why, function()
        test.assertEqual(case.key, normalizer(case.rules):Key(case.input))
    end)
end

test.test("name key rejects anything that isn't a name", function()
    local names = normalizer(FOREVER)

    test.assertEqual(nil, names:Key(nil))
    test.assertEqual(nil, names:Key(""))
    test.assertEqual(nil, names:Key("   -Camelot"))
    test.assertEqual(nil, names:Key(42))
end)

test.test("display names drop the home realm and keep other realms", function()
    local forever = normalizer(FOREVER)
    local retail = normalizer(RETAIL)

    test.assertEqual("Tool Box", forever:Display("Tool Box-Camelot"))
    test.assertEqual("Tool Box", forever:Display("Tool  Box"))
    test.assertEqual("Toolbox", retail:Display("Toolbox-Area52"))
    test.assertEqual("Visitor-Stormrage", retail:Display("Visitor-Stormrage"))
end)

test.test("first names exist only for Forever two-part names", function()
    test.assertEqual("tool", normalizer(FOREVER):FirstName("Tool Box-Camelot"))
    test.assertEqual("zélie", normalizer(FOREVER):FirstName("ZÉLIE Rune"))
    test.assertEqual(nil, normalizer(RETAIL):FirstName("Toolbox-Area52"))
end)

test.test("same-character checks ignore case and an omitted home realm", function()
    local names = normalizer(FOREVER)

    test.assertTrue(names:IsSameCharacter("Tool Box", "tool box-Camelot"))
    test.assertFalse(names:IsSameCharacter("Tool Box", "Tool Box-Other"))
    test.assertFalse(names:IsSameCharacter(nil, nil))
end)
