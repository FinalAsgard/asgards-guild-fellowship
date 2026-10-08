local _, addon = ...

-- Decides who counts as an officer: a guild member whose rank can view
-- officer notes. The guild master's rank always counts. This is the one
-- officer rule, for guild sync and every later officer feature, so promoting
-- or demoting someone changes their authority with nothing to set up.
--
-- Pure: the guild facts are passed in.
--   rankOf(key)                     -> the character's 0-based guild rank
--                                      index, or nil when it isn't a current
--                                      guild member
--   rankCanViewOfficerNotes(rank)   -> true, false, or nil when the client
--                                      can't say
local OfficerAuthority = {
    GUILD_MASTER_RANK = 0,
}
addon.OfficerAuthority = OfficerAuthority

local Authority = {}
Authority.__index = Authority

function OfficerAuthority.Create(options)
    return setmetatable({
        rankOf = options.rankOf,
        rankCanViewOfficerNotes = options.rankCanViewOfficerNotes,
    }, Authority)
end

-- True only when `key` is a current guild member with an officer rank. An
-- unknown character, or a rank the client can't describe, is not an officer.
function Authority:IsOfficer(key)
    if type(key) ~= "string" then
        return false
    end
    local rank = self.rankOf(key)
    if type(rank) ~= "number" then
        return false
    end
    if rank == OfficerAuthority.GUILD_MASTER_RANK then
        return true
    end
    return self.rankCanViewOfficerNotes(rank) == true
end
