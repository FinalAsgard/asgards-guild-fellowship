local test = require("tests.test_helper")

test.test("empty slash input prints concise help", function()
    local messages = {}
    local addon = test.newAddon("Core/CommandRouter.lua")
    local router = addon.CommandRouter.Create(function(message)
        table.insert(messages, message)
    end)

    router:Register("help", "show available commands", function()
        router:PrintHelp()
    end)

    router:Register("roster", "show or hide the roster window", function() end)

    test.assertTrue(router:Execute(""))
    -- A header, then one line per command, in the order they were added.
    test.assertEqual(3, #messages)
    test.assertEqual("|cffd4af37[Guild Fellowship]|r Commands:", messages[1])
    test.assertEqual("  /agf help - show available commands", messages[2])
    test.assertEqual("  /agf roster - show or hide the roster window", messages[3])
end)

test.test("dev build help uses the dev tag and command", function()
    local messages = {}
    local addon = test.newAddonNamed("AsgardsGuildFellowshipDev", "Core/CommandRouter.lua")
    local router = addon.CommandRouter.Create(function(message)
        table.insert(messages, message)
    end)
    router:Register("help", "show available commands", function()
        router:PrintHelp()
    end)

    test.assertTrue(router:Execute("HELP"))
    test.assertEqual("|cffd4af37[Guild Fellowship (Dev)]|r Commands:", messages[1])
    test.assertEqual("  /agfdev help - show available commands", messages[2])
end)

test.test("commands receive arguments and can be extended", function()
    local received
    local addon = test.newAddon("Core/CommandRouter.lua")
    local router = addon.CommandRouter.Create()

    test.assertTrue(router:Register("example", "exercise the router", function(arguments)
        received = arguments
    end))

    test.assertTrue(router:Execute("  ExAmPlE   one two  "))
    test.assertEqual("one two", received)
end)

test.test("invalid registrations are refused", function()
    local addon = test.newAddon("Core/CommandRouter.lua")
    local router = addon.CommandRouter.Create()

    test.assertFalse(router:Register("", "empty", function() end))
    test.assertFalse(router:Register("nohandler", "missing handler"))
end)

test.test("unknown commands fail safely and point to help", function()
    local message
    local addon = test.newAddon("Core/CommandRouter.lua")
    local router = addon.CommandRouter.Create(function(output)
        message = output
    end)

    test.assertFalse(router:Execute("missing"))
    test.assertContains(message, "Unknown command 'missing'")
    test.assertContains(message, "/agf help")
end)
