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
