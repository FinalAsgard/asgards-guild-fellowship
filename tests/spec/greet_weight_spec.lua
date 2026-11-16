local test = require("tests.test_helper")

local function load()
    return test.newAddon("Core/GreetWeight.lua").GreetWeight
end

test.test("greet weight: each greeting adds 1, up to 6", function()
    local GreetWeight = load()
    local record = nil
    local count
    for count = 1, 8 do
        record = GreetWeight.Added(record, 1000)
    end
    test.assertEqual(6, record.weight)
    test.assertEqual(1000, record.at)
end)

test.test("greet weight: fades 0.2 a minute down to 0, and an unusable record counts as none", function()
    local GreetWeight = load()
    local record = { weight = 3, at = 1000 }
    test.assertEqual(3, GreetWeight.Current(record, 1000))
    test.assertEqual(2, GreetWeight.Current(record, 1300))
    test.assertEqual(0, GreetWeight.Current(record, 1900))
    test.assertEqual(0, GreetWeight.Current(record, 99999))
    test.assertEqual(0, GreetWeight.Current(nil, 1000))
    test.assertEqual(0, GreetWeight.Current({ weight = "3", at = 1000 }, 1000))
    test.assertEqual(0, GreetWeight.Current({ weight = 9, at = 1000 }, 1000))
    -- A clock that went backwards doesn't add weight.
    test.assertEqual(3, GreetWeight.Current(record, 900))
end)

test.test("greet weight: 2.5 seconds a weight, only with 3 or more add-on users online", function()
    local GreetWeight = load()
    test.assertEqual(15, GreetWeight.ExtraDelay(6, 3))
    test.assertEqual(2.5, GreetWeight.ExtraDelay(1, 10))
    test.assertEqual(0, GreetWeight.ExtraDelay(6, 2))
    test.assertEqual(0, GreetWeight.ExtraDelay(6, nil))
    test.assertEqual(0, GreetWeight.ExtraDelay(0, 5))
end)

test.test("greet weight: the probe says the weight, the count and the extra wait", function()
    local GreetWeight = load()
    local lines = GreetWeight.ProbeLines(2, 4)
    test.assertEqual("Greet weight: 2.0 of 6 (fades 0.2 a minute)", lines[1])
    test.assertEqual("Guildmates online with the add-on, counting you: 4", lines[2])
    test.assertEqual("New prompts wait 5.0 seconds longer so others get a turn.", lines[3])
    test.assertEqual("No extra wait: it applies only with 3 or more add-on users online.",
        GreetWeight.ProbeLines(2, 2)[3])
    test.assertEqual("Guildmates online with the add-on, counting you: unknown", GreetWeight.ProbeLines(0, nil)[2])
    test.assertEqual("No extra wait.", GreetWeight.ProbeLines(0, nil)[3])
end)
