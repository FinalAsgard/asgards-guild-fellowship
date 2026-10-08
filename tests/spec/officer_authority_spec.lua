local test = require("tests.test_helper")

-- Officers are current members whose rank can view officer notes; the guild
-- master's rank always counts.
local RANKS = {
    ["gm-area52"] = 0,
    ["toolbox-area52"] = 1,
    ["hammer-area52"] = 3,
}

local function newAuthority(flags)
    local addon = test.newAddon("Core/OfficerAuthority.lua")
    return addon.OfficerAuthority.Create({
        rankOf = function(key)
            return RANKS[key]
        end,
        rankCanViewOfficerNotes = function(rank)
            return flags[rank]
        end,
    })
end

test.test("a rank that can view officer notes is an officer rank", function()
    local authority = newAuthority({ [1] = true, [3] = false })

    test.assertTrue(authority:IsOfficer("toolbox-area52"))
    test.assertFalse(authority:IsOfficer("hammer-area52"))
end)

test.test("the guild master's rank is always an officer rank", function()
    local authority = newAuthority({ [0] = false })

    test.assertTrue(authority:IsOfficer("gm-area52"))
end)

test.test("a character outside the guild is never an officer", function()
    local authority = newAuthority({ [1] = true })

    test.assertFalse(authority:IsOfficer("visitor-stormrage"))
    test.assertFalse(authority:IsOfficer(nil))
end)

test.test("a rank the client can't describe is not an officer rank", function()
    local authority = newAuthority({})

    test.assertFalse(authority:IsOfficer("toolbox-area52"))
end)

test.test("promotion and demotion change authority with nothing to set up", function()
    local addon = test.newAddon("Core/OfficerAuthority.lua")
    local rank = 3
    local authority = addon.OfficerAuthority.Create({
        rankOf = function()
            return rank
        end,
        rankCanViewOfficerNotes = function(index)
            return index <= 1
        end,
    })

    test.assertFalse(authority:IsOfficer("hammer-area52"))
    rank = 1
    test.assertTrue(authority:IsOfficer("hammer-area52"))
    rank = 2
    test.assertFalse(authority:IsOfficer("hammer-area52"))
end)
