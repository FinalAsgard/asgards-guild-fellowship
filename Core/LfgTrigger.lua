local _, addon = ...

-- When the Guild LFG Board asks the player about their party, and what
-- happens to their listing as the party changes. Each party update is
-- compared with the one before:
--
--   a party forms with the player leading (their invite)
--       listed solo already  -> JOINED: the solo listing becomes the party's
--       otherwise            -> ASK what it's for
--   the player joins someone else's party while listed solo -> END
--   the player is made leader
--       the old leader's party was listed -> TAKE_OVER that listing quietly
--       otherwise, not listed             -> ASK
--   the player hands the lead on while listed -> HAND_OFF (the new leader
--       takes it over)
--   the party becomes a raid with the player leading and listed -> RAID
--   the party is gone (disbanded, or the player left) while listed -> END
--   the party fills up, with the player leading, unlisted, and at least
--       one other guildmate in it -> LIST_QUIETLY with a guessed purpose
--       (no other guildmate: nothing)
--
-- With the LFG button hidden ("not participating"), nothing is ever asked:
-- where the player would be asked, the party is listed quietly instead,
-- with a REMIND chat line of how to take part.
--
-- Asking is snoozed for the rest of a party once the player says Not
-- looking (or ignores the question), and for every new party for
-- SNOOZE_SECONDS after "don't ask for 30 minutes". Snoozes live only in
-- this session. Pure: the facts and the time are handed in.
local LfgTrigger = {
    SNOOZE_SECONDS = 30 * 60,
    ASK = "ask",
    JOINED = "joined",
    TAKE_OVER = "takeOver",
    HAND_OFF = "handOff",
    RAID = "raid",
    END = "end",
    LIST_QUIETLY = "listQuietly",
    REMIND = "remind",
    -- A party this big, not a raid, is full.
    PARTY_SIZE = 5,
}
addon.LfgTrigger = LfgTrigger

local Trigger = {}
Trigger.__index = Trigger

function LfgTrigger.Create()
    return setmetatable({ state = { inGroup = false }, party = 0 }, Trigger)
end

-- Whether asking is snoozed at `now`.
function Trigger:snoozed(now)
    return self.partySnoozed == self.party
        or (self.snoozedUntil ~= nil and type(now) == "number" and now < self.snoozedUntil)
end

-- The party changed (or may have). facts:
--   inGroup    in a party or raid
--   isLeader   the player leads it
--   isRaid     it's a raid
--   leaderKey  who leads it (any stable id), or nil
--   listed     the player's listing is live
--   listingOf  function(leaderKey) -> that leader's listing on the board,
--              or nil
--   size       how many are in the party
--   guildmates how many of the others are in the guild
--   hidden     the LFG button is hidden
-- Returns a list of { action, listing? } to carry out, in order.
function Trigger:Observe(facts, now)
    local before = self.state
    local actions = {}
    local function act(action, listing)
        table.insert(actions, { action = action, listing = listing })
    end
    local full = facts.inGroup == true and not facts.isRaid
        and type(facts.size) == "number" and facts.size >= LfgTrigger.PARTY_SIZE
    self.state = {
        inGroup = facts.inGroup == true,
        isLeader = facts.isLeader == true,
        isRaid = facts.isRaid == true,
        leaderKey = facts.leaderKey,
        full = full,
    }
    local listed = facts.listed == true
    -- Where the player would be asked: asked, or with the button hidden,
    -- listed quietly and reminded.
    local function ask()
        if self:snoozed(now) then
            return
        end
        if facts.hidden then
            listed = true
            act(LfgTrigger.LIST_QUIETLY)
            act(LfgTrigger.REMIND)
        else
            self.asking = true
            act(LfgTrigger.ASK)
        end
    end
    if not facts.inGroup then
        if before.inGroup and listed then
            act(LfgTrigger.END)
        end
        self.asking = false
        return actions
    end
    if not before.inGroup then
        -- A new party.
        self.party = self.party + 1
        self.asking = false
        if facts.isLeader then
            if listed then
                act(LfgTrigger.JOINED)
            else
                ask()
            end
        elseif listed then
            act(LfgTrigger.END)
            listed = false
        end
    elseif facts.isLeader and not before.isLeader then
        local old = before.leaderKey ~= nil and facts.listingOf ~= nil and facts.listingOf(before.leaderKey) or nil
        if old ~= nil then
            listed = true
            act(LfgTrigger.TAKE_OVER, old)
        elseif not listed then
            ask()
        end
    elseif not facts.isLeader and before.isLeader then
        self.asking = false
        if listed then
            act(LfgTrigger.HAND_OFF)
        end
        return actions
    elseif facts.isLeader and facts.isRaid and not before.isRaid and listed then
        act(LfgTrigger.RAID)
    end
    -- Filled up with another guildmate in it: listed quietly, unless the
    -- player said Not looking for this party.
    local filled = full and not (before.inGroup and before.full)
    if filled and facts.isLeader and not listed and (facts.guildmates or 0) >= 1
        and self.partySnoozed ~= self.party
    then
        -- No question for a party that's being listed anyway.
        local index
        for index = #actions, 1, -1 do
            if actions[index].action == LfgTrigger.ASK then
                table.remove(actions, index)
            end
        end
        self.asking = false
        act(LfgTrigger.LIST_QUIETLY)
    end
    return actions
end

-- Whether the player is being asked about their party now.
function Trigger:Asking()
    return self.asking == true
end

-- The question was answered by listing the party.
function Trigger:Answered()
    self.asking = false
end

-- Not looking (or the question ignored): nothing more is asked in this
-- party.
function Trigger:NotLooking()
    self.asking = false
    self.partySnoozed = self.party
end

-- "Don't ask for 30 minutes": nothing is asked in this party, or any new
-- one until then.
function Trigger:Snooze(now)
    self:NotLooking()
    self.snoozedUntil = (type(now) == "number" and now or 0) + LfgTrigger.SNOOZE_SECONDS
end
