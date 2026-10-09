local test = require("tests.test_helper")

local START = 1790000000
local WINDOW = 15 * 60

local function newTally()
    return test.newAddon("Core/GreetTally.lua").GreetTally.Create(function()
        return WINDOW
    end)
end

test.test("greet tally: each greeter counts once toward the cap", function()
    local tally = newTally()

    test.assertEqual(1, tally:Add(7, "ann", START, START + 5))
    -- The same greeter heard again (a duplicate message) counts once.
    test.assertEqual(1, tally:Add(7, "ann", START, START + 6))
    test.assertFalse(tally:Reached(7, 2, START + 6))
    test.assertTrue(tally:Reached(7, 1, START + 6))

    test.assertEqual(2, tally:Add(7, "bob", START, START + 8))
    test.assertTrue(tally:Reached(7, 2, START + 8))
    test.assertFalse(tally:Reached(7, 3, START + 8))
    test.assertEqual(3, tally:Add(7, "cal", START, START + 9))
    test.assertTrue(tally:Reached(7, 3, START + 9))
    -- Other players have their own counts.
    test.assertEqual(0, tally:Count(8, START + 9))
end)

test.test("greet tally: a count lasts until the welcome-back window passes after its latest greeting", function()
    local tally = newTally()
    tally:Add(7, "ann", START, START)
    tally:Add(7, "bob", START, START + 60)

    test.assertTrue(tally:Reached(7, 2, START + 60 + WINDOW - 1))
    test.assertFalse(tally:Reached(7, 2, START + 60 + WINDOW))
    test.assertEqual(0, tally:Count(7, START + 60 + WINDOW))

    -- A new arrival starts from zero, and the same greeters count again.
    local later = START + 60 + WINDOW + 30
    test.assertEqual(1, tally:Add(7, "ann", later, later))
end)

test.test("greet tally: a greeting for an arrival that's long past isn't counted", function()
    local tally = newTally()

    test.assertEqual(0, tally:Add(7, "ann", START, START + WINDOW))
    test.assertEqual(1, tally:Add(7, "bob", START, START + WINDOW - 1))
    -- Unusable reports are ignored without errors.
    test.assertEqual(1, tally:Add(7, nil, START, START + 10))
    test.assertEqual(1, tally:Add(7, "cal", "soon", START + 10))
    test.assertEqual(0, tally:Add(nil, "cal", START, START + 10))
    test.assertEqual(0, tally:Count(7, nil))
end)
