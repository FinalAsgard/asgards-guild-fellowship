local test = require("tests.test_helper")

local function load()
    return test.newAddon("Core/GreetingLibrary.lua")
end

-- Always picks the lowest choice, so specs know which greeting comes next.
local function lowest(low)
    return low
end

test.test("greeting library: every category starts with the starter greetings", function()
    local addon = load()
    local state = {}
    local library = addon.GreetingLibrary.Create(state, lowest)

    test.assertEqual("Hey {name}!", library:Greetings("login")[1])

    local category
    for _, category in ipairs({ "join", "login", "welcomeBack", "longAbsence" }) do
        test.assertEqual(3, #state.greetings[category], category)
    end
    -- The saved copy is the user's own; the starters stay untouched.
    state.greetings.login[1] = "Yo {name}"
    test.assertEqual("Hey {name}!", addon.GreetingLibrary.STARTERS.login[1])
end)

test.test("greeting library: the same greeting is never picked twice in a row", function()
    local addon = load()
    local state = { greetings = { login = { "One", "Two", "Three" } } }
    local library = addon.GreetingLibrary.Create(state, lowest)

    test.assertEqual("One", library:Pick("login"))
    test.assertEqual("Two", library:Pick("login"))
    test.assertEqual("One", library:Pick("login"))
    test.assertEqual("One", state.lastUsed.login)

    -- The last one used is saved, so a new session doesn't repeat it either.
    local again = addon.GreetingLibrary.Create(state, lowest)
    test.assertEqual("Two", again:Pick("login"))
end)

test.test("greeting library: a category with one greeting always uses it", function()
    local addon = load()
    local library = addon.GreetingLibrary.Create({ greetings = { login = { "Only" } } }, lowest)

    test.assertEqual("Only", library:Pick("login"))
    test.assertEqual("Only", library:Pick("login"))
end)

test.test("greeting library: greetings are trimmed, empty ones dropped, and long ones cut", function()
    local addon = load()
    local long = string.rep("a", 300)
    local state = { greetings = { login = { "  Hi {name}  ", "", "   ", "Two\nlines", long, 42 } } }
    local library = addon.GreetingLibrary.Create(state, lowest)

    local greetings = library:Greetings("login")

    test.assertEqual(3, #greetings)
    test.assertEqual("Hi {name}", greetings[1])
    test.assertEqual("Two lines", greetings[2])
    test.assertEqual(255, #greetings[3])
end)

test.test("greeting library: {name} and {character} are filled in, other braces left alone", function()
    local addon = load()
    local render = addon.GreetingLibrary.Render

    test.assertEqual("Hi TheTool on Hammer!", render("Hi {name} on {character}!", {
        name = "TheTool", character = "Hammer",
    }))
    test.assertEqual("Hi {friend}, TheTool", render("Hi {friend}, {name}", { name = "TheTool" }))
    test.assertEqual("Hello Mr. Box, Box", render("Hello Mr. {MainLast}, {mainlast}", { mainlast = "Box" }))
    test.assertEqual("100% TheTool%", render("100% {name}", { name = "TheTool%" }))
    test.assertEqual(255, #render("{name}" .. string.rep("b", 250), { name = "Twelve chars" }))
end)

test.test("greeting library: unusable or missing saved greetings give nothing to say", function()
    local addon = load()

    test.assertEqual(nil, addon.GreetingLibrary.Create(nil, lowest):Pick("login"))
    test.assertEqual(nil, addon.GreetingLibrary.Create({ greetings = "corrupt" }, lowest):Pick("login"))
    test.assertEqual(nil, addon.GreetingLibrary.Create({ greetings = { login = "x" } }, lowest):Pick("login"))
    test.assertEqual(nil, addon.GreetingLibrary.Create({ greetings = { login = {} } }, lowest):Pick("login"))
    test.assertEqual(nil, addon.GreetingLibrary.Create({}, lowest):Pick("unknown"))
end)

test.test("greeting library: a retired starter in saved greetings is replaced", function()
    local addon = load()
    local state = { greetings = { login = { "Hey {name}!", "Evening, {name}!" } } }
    local library = addon.GreetingLibrary.Create(state, lowest)

    test.assertEqual("Hello, {name}!", library:Greetings("login")[2])
    test.assertEqual("Hello, {name}!", state.greetings.login[2])
end)

test.test("greeting library: greetings can be added, edited and deleted", function()
    local addon = load()
    local state = { greetings = { login = { "One", "", "Two" } } }
    local library = addon.GreetingLibrary.Create(state, lowest)

    -- Positions are the ones Greetings shows, with the blank line gone.
    test.assertEqual(3, library:Add("login", "  Three\n"))
    test.assertTrue(library:Edit("login", 2, "Second"))
    test.assertTrue(library:Remove("login", 1))

    test.assertEqual("Second,Three", table.concat(library:Greetings("login"), ","))
    -- Saved account-wide, so a new library (the next prompt) sees them.
    test.assertEqual("Second,Three", table.concat(
        addon.GreetingLibrary.Create(state, lowest):Greetings("login"), ","))
end)

test.test("greeting library: empty and over-long greetings are refused, not cut", function()
    local addon = load()
    local state = {}
    local library = addon.GreetingLibrary.Create(state, lowest)

    local ok, reason = library:Add("join", "   ")
    test.assertEqual(nil, ok)
    test.assertEqual("it's empty", reason)

    ok, reason = library:Edit("join", 1, string.rep("a", 256))
    test.assertEqual(nil, ok)
    test.assertContains(reason, "255 characters")
    -- Exactly one message's worth fits, after the three starters.
    test.assertEqual(4, library:Add("join", string.rep("a", 255)))
    test.assertEqual(255, #state.greetings.join[4])

    test.assertEqual(nil, library:Edit("join", 9, "Hi"))
    test.assertEqual(nil, library:Remove("join", 9))
    test.assertEqual(nil, library:Add("party", "Hi"))
end)

test.test("greeting library: restoring puts back the starters in one category or all", function()
    local addon = load()
    local starters = addon.GreetingLibrary.STARTERS
    local state = { greetings = { login = { "Mine" }, join = {}, welcomeBack = { "Also mine" } } }
    local library = addon.GreetingLibrary.Create(state, lowest)

    test.assertTrue(library:Restore("login"))
    test.assertEqual(table.concat(starters.login, ","), table.concat(library:Greetings("login"), ","))
    test.assertEqual("Also mine", library:Greetings("welcomeBack")[1])
    test.assertEqual(0, #library:Greetings("join"))

    test.assertTrue(library:Restore())
    local index
    for index = 1, #addon.GreetingLibrary.CATEGORIES do
        local category = addon.GreetingLibrary.CATEGORIES[index].id
        test.assertEqual(table.concat(starters[category], ","), table.concat(library:Greetings(category), ","))
    end
    -- The saved copies are the user's own again, apart from the starters.
    library:Add("login", "New")
    test.assertEqual(3, #starters.login)
end)

test.test("greeting library: without usable saved data nothing is changed", function()
    local addon = load()
    local corrupt = { greetings = { login = "x" } }

    local ok, reason = addon.GreetingLibrary.Create(nil, lowest):Add("login", "Hi")
    test.assertEqual(nil, ok)
    test.assertEqual("saved data is unavailable", reason)
    test.assertEqual(nil, addon.GreetingLibrary.Create(nil, lowest):Restore())

    ok, reason = addon.GreetingLibrary.Create(corrupt, lowest):Remove("login", 1)
    test.assertEqual(nil, ok)
    test.assertEqual("the saved greetings are unreadable", reason)
    test.assertEqual("x", corrupt.greetings.login)
end)

test.test("greeting library: every category and placeholder is described for the window", function()
    local addon = load()
    local library = addon.GreetingLibrary

    test.assertEqual(4, #library.CATEGORIES)
    local index
    for index = 1, #library.CATEGORIES do
        test.assertTrue(library.STARTERS[library.CATEGORIES[index].id] ~= nil)
    end
    local described = {}
    for index = 1, #library.PLACEHOLDERS do
        described[string.lower(library.PLACEHOLDERS[index][1])] = true
    end
    local names = { "name", "main", "mainfirst", "mainlast", "character", "characterfirst", "characterlast" }
    for index = 1, #names do
        test.assertTrue(described["{" .. names[index] .. "}"], names[index])
    end
    test.assertEqual(#names, #library.PLACEHOLDERS)
end)

test.test("greeting library: a long greeting is never cut in the middle of a letter", function()
    local addon = load()
    local render = addon.GreetingLibrary.Render

    -- "é" is two bytes; the limit falls between them, so the cut backs off.
    local rendered = render(string.rep("a", 254) .. "{name}", { name = "éa" })
    test.assertEqual(254, #rendered)
    test.assertEqual(string.rep("a", 254), rendered)
    test.assertEqual(255, #render(string.rep("a", 253) .. "{name}", { name = "éa" }))
    test.assertEqual(254, #addon.GreetingLibrary.Clean(string.rep("b", 254) .. "é"))
end)
