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
-- A party with anyone outside the guild in it is only listed when someone
-- wants it: where the player would be asked what it's for, the GATE
-- question asks first whether to list it at all, and it's never listed
-- quietly (filling up, or with the button hidden).
--
-- Contact selection, for a party whose leader isn't in the guild (or is
-- logged off): its guildmates are asked (GATE), and the first to say yes
-- claims contact (CLAIM; the others hear it through Claimed). The contact
-- edits the listing and is whom guildmates whisper. A guild leader who
-- hands the lead to someone outside the guild stays on as contact. When
-- the contact or the guild leader leaves or logs off, the first of the
-- party's guildmates still there (by key) takes the listing over and
-- becomes contact; with none left, it's gone with them.
--
-- The slot-open path: when someone leaves a full, listed party, its
-- guildmates are asked (SLOT_OPEN, with an orange glow and no popup)
-- whether to fill the empty slot, and the listing stays as it was until
-- someone answers. Yes posts the open slot, No keeps it off the board.
-- With no answer it's posted after SLOT_SECONDS, unless another member
-- leaves within them (a party winding down), which keeps it off; the
-- party disbanding ends it all. With the button hidden nothing is asked
-- or posted: the lister gets a SLOT_REMIND chat line. The party filling
-- up again closes the question.
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
    -- Ask whether to list a party with players outside the guild.
    GATE = "gate",
    -- The player is now the contact: tell the party's guildmates.
    CLAIM = "claim",
    -- Someone left the full party: fill the empty slot?
    SLOT_OPEN = "slotOpen",
    -- Someone left, with the button hidden: a chat line, nothing posted.
    SLOT_REMIND = "slotRemind",
    -- How long an open slot waits for an answer before it's posted.
    SLOT_SECONDS = 60,
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
--   outsiders  how many of the others aren't in the guild
--   guildLed   the leader is the player, or a guildmate who's logged in
--   selfKey    the player's key
--   present    the keys of the party's guildmates who are logged in, the
--              player's among them, sorted
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
        guildLed = facts.guildLed ~= false,
        size = type(facts.size) == "number" and facts.size or 0,
    }
    local listed = facts.listed == true
    local gated = (facts.outsiders or 0) > 0
    -- Where the player would be asked: asked, or with the button hidden,
    -- listed quietly and reminded. With outsiders in the party (or `gate`),
    -- asked whether to list it, and never listed quietly.
    local function ask(gate)
        gate = gate or gated
        if self:snoozed(now) then
            return
        end
        if facts.hidden then
            if not gate then
                listed = true
                act(LfgTrigger.LIST_QUIETLY)
                act(LfgTrigger.REMIND)
            end
        else
            self.asking = gate and "gate" or "purpose"
            act(gate and LfgTrigger.GATE or LfgTrigger.ASK)
        end
    end
    if not facts.inGroup then
        if before.inGroup and listed then
            act(LfgTrigger.END)
        end
        self.asking = false
        self.contact = nil
        self.slot = nil
        return actions
    end
    if facts.guildLed ~= false then
        self.contact = nil
    end
    if not before.inGroup then
        -- A new party.
        self.party = self.party + 1
        self.asking = false
        self.contact = nil
        self.slot = nil
        if facts.isLeader then
            if listed then
                act(LfgTrigger.JOINED)
            else
                ask()
            end
        else
            if listed then
                act(LfgTrigger.END)
                listed = false
            end
            -- Led from outside the guild: its guildmates are asked.
            if facts.guildLed == false then
                ask(true)
            end
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
        if listed and facts.guildLed == false then
            -- Handed to someone outside the guild: the player stays on as
            -- contact.
            self.contact = facts.selfKey
            act(LfgTrigger.CLAIM)
        elseif listed then
            act(LfgTrigger.HAND_OFF)
        end
        -- Refilled (or made a raid) in the same update: no slot is open.
        if full or facts.isRaid then
            self.slot = nil
        end
        return actions
    elseif facts.isLeader and facts.isRaid and not before.isRaid and listed then
        act(LfgTrigger.RAID)
    elseif facts.guildLed == false and not facts.isLeader then
        self:succeed(facts, before, listed, act, ask)
    end
    -- Someone outside the guild joined while the player was being asked
    -- what the party's for: they're asked whether to list it at all.
    if before.inGroup and gated and self.asking == "purpose" then
        self.asking = "gate"
        act(LfgTrigger.GATE)
    end
    self:slotPath(facts, before, full, listed, now, act)
    -- Filled up with another guildmate in it: listed quietly, unless the
    -- player said Not looking for this party.
    local filled = full and not (before.inGroup and before.full)
    if filled and facts.isLeader and not listed and (facts.guildmates or 0) >= 1 and not gated
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

-- In a party led from outside the guild, the same party as before: when
-- whoever had the listing (the contact, or the guild leader before) is
-- gone, the first guildmate still there takes it over; when the party has
-- just come to be led from outside, with nothing to take over, its
-- guildmates are asked.
function Trigger:succeed(facts, before, listed, act, ask)
    local present = facts.present or {}
    local function isPresent(key)
        local index
        for index = 1, #present do
            if present[index] == key then
                return true
            end
        end
        return false
    end
    if self.contact ~= nil and isPresent(self.contact) then
        return
    end
    local was = self.contact
    if was == nil and before.guildLed then
        was = before.leaderKey
    end
    self.contact = nil
    local old = was ~= nil and facts.listingOf ~= nil and facts.listingOf(was) or nil
    if old ~= nil and present[1] ~= nil then
        self.contact = present[1]
        if present[1] == facts.selfKey and not listed then
            self.asking = false
            act(LfgTrigger.TAKE_OVER, old)
            act(LfgTrigger.CLAIM)
        end
    elseif old == nil and before.guildLed and not listed then
        ask(true)
    end
end

-- Someone leaving a full party, the same party as before: the slot is
-- open (or, with the button hidden, the lister is reminded). Another
-- leaving while it's open keeps it off the board; filling up closes it.
function Trigger:slotPath(facts, before, full, listed, now, act)
    if full or facts.isRaid then
        self.slot = nil
        return
    end
    local size = type(facts.size) == "number" and facts.size or 0
    if not before.inGroup or before.isRaid or size >= before.size then
        return
    end
    if self:SlotOpen() then
        self.slot.state = "kept"
        return
    end
    if not before.full or self.partySnoozed == self.party then
        return
    end
    local key = self.contact or facts.leaderKey
    if not listed and (key == nil or facts.listingOf == nil or facts.listingOf(key) == nil) then
        return
    end
    if facts.hidden then
        -- The lister's slot waits for the button to come back (Resume).
        self.slot = { state = "kept" }
        if facts.isLeader or (self.contact ~= nil and self.contact == facts.selfKey) then
            self.slot.state = "waiting"
            act(LfgTrigger.SLOT_REMIND)
        end
        return
    end
    self.slot = { state = "open", at = type(now) == "number" and now or 0 }
    act(LfgTrigger.SLOT_OPEN)
end

-- Whether "fill the empty slot?" is waiting for an answer.
function Trigger:SlotOpen()
    return self.slot ~= nil and self.slot.state == "open"
end

-- The LFG button was hidden: an open slot waits, unasked and unposted, for
-- it to come back.
function Trigger:Pause()
    if self:SlotOpen() then
        self.slot.state = "waiting"
    end
end

-- The LFG button came back at `now`: a slot waiting for it is asked about
-- again, with SLOT_SECONDS to answer. True when it was.
function Trigger:Resume(now)
    if self.slot == nil or self.slot.state ~= "waiting" then
        return false
    end
    self.slot = { state = "open", at = type(now) == "number" and now or 0 }
    return true
end

-- The open slot went SLOT_SECONDS without an answer by `now`: it's posted.
-- True when that happened now.
function Trigger:SlotDue(now)
    if not self:SlotOpen() or type(now) ~= "number" or now - self.slot.at < LfgTrigger.SLOT_SECONDS then
        return false
    end
    self.slot.state = "posted"
    return true
end

-- "Fill the empty slot?" answered (by the player or a guildmate in the
-- party): `yes` posts it, no keeps it off. True when it was open.
function Trigger:SlotAnswered(yes)
    if not self:SlotOpen() then
        return false
    end
    self.slot.state = yes and "posted" or "kept"
    return true
end

-- Whether the player is being asked about their party now (what it's for,
-- or whether to list it).
function Trigger:Asking()
    return self.asking ~= nil and self.asking ~= false
end

-- Whether the question is whether to list a party with outsiders in it.
function Trigger:Gating()
    return self.asking == "gate"
end

-- Who the party's contact is (a key), or nil.
function Trigger:Contact()
    return self.contact
end

-- The player (`selfKey`) said yes to listing a party led from outside the
-- guild: they're its contact.
function Trigger:Claim(selfKey)
    self.asking = false
    self.contact = selfKey
end

-- Guildmate `key` in the party claimed contact. Two at once: the lower key
-- keeps it, on every client. True when the player (`selfKey`) was contact
-- and no longer is.
function Trigger:Claimed(key, selfKey)
    if key == nil or key == selfKey then
        return false
    end
    local mine = self.contact ~= nil and self.contact == selfKey
    if self.contact ~= nil and tostring(self.contact) < tostring(key) then
        return false
    end
    self.contact = key
    self.asking = false
    return mine
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
