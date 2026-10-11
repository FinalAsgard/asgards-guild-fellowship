local test = require("tests.test_helper")

local START = 1790000000
local HOUR = 60 * 60

-- A policy over plain state a spec can change: `state.canInvite`,
-- `state.optedIn` and `state.hasAd`, all true to start with.
local function setup()
    local addon = test.newAddon("Core/RecruitLedger.lua", "Core/RecruitPolicy.lua")
    local state = { canInvite = true, optedIn = true, hasAd = true }
    local policy = addon.RecruitPolicy.Create({
        canInvite = function()
            return state.canInvite
        end,
        optedIn = function()
            return state.optedIn
        end,
        hasAd = function()
            return state.hasAd
        end,
    })
    local ledger = addon.RecruitLedger.Create({}, function()
        return HOUR
    end)
    local location = { key = "map:1455", name = "Ironforge", general = 1 }
    return addon, policy, state, ledger, location
end

test.test("recruit policy: an unadvertised General is due, named for its zone", function()
    local addon, policy, _, ledger, location = setup()

    local due = policy:Due(location, ledger, START)

    test.assertEqual(1, #due)
    test.assertEqual(addon.RecruitLedger.GeneralKey("map:1455"), due[1].key)
    test.assertEqual(addon.RecruitPolicy.GENERAL, due[1].channel)
    test.assertEqual("map:1455", due[1].zoneKey)
    test.assertEqual("Ironforge", due[1].zoneName)
    test.assertEqual(1, due[1].channelNumber)
end)

test.test("recruit policy: a channel advertised within the gap isn't due until the gap passes", function()
    local addon, policy, _, ledger, location = setup()
    ledger:Record(addon.RecruitLedger.GeneralKey("map:1455"), START)

    test.assertEqual(0, #policy:Due(location, ledger, START + HOUR - 1))
    test.assertEqual(1, #policy:Due(location, ledger, START + HOUR))
end)

test.test("recruit policy: no prompt without permission, opt-in, or an ad", function()
    local reasons = { "canInvite", "optedIn", "hasAd" }
    local index
    for index = 1, #reasons do
        local _, policy, state, ledger, location = setup()
        state[reasons[index]] = false

        test.assertFalse(policy:Allowed(), reasons[index])
        test.assertEqual(0, #policy:Due(location, ledger, START), reasons[index])
    end
end)

test.test("recruit policy: failing checks count as no", function()
    local addon = test.newAddon("Core/RecruitLedger.lua", "Core/RecruitPolicy.lua")
    local policy = addon.RecruitPolicy.Create({
        canInvite = function() error("boom") end,
        optedIn = function() return true end,
        hasAd = function() return true end,
    })

    test.assertFalse(policy:Allowed())
end)

test.test("recruit policy: no prompt in an unknown zone or outside its General channel", function()
    local _, policy, _, ledger = setup()

    test.assertEqual(0, #policy:Due(nil, ledger, START))
    test.assertEqual(0, #policy:Due({ name = "Nowhere", general = 1 }, ledger, START))
    test.assertEqual(0, #policy:Due({ key = "map:1455", name = "Ironforge" }, ledger, START))
end)
