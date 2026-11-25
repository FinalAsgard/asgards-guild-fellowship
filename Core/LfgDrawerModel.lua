local _, addon = ...

-- What the LFG button and its drawer show, from the party's state and the
-- board. Pure: the facts are handed in on every Update.
--
-- The count is how many listed groups the current character could join,
-- in a party or not. The gold glow means a relevant group appeared since
-- the drawer was last opened; each new one pulses once (and, when the
-- player wants it, gets a chat line). It never shows in a party, in combat,
-- in an instance or in Do Not Disturb. Groups that appear while in a party
-- or in Do Not Disturb never glow later; ones that appear in combat or an
-- instance glow once that's over, if they're still there. The orange glow
-- (a slot opened in the player's party) wins over gold.
--
-- The drawer's top section asks whether to list a party with outsiders in
-- it, or the leader what their party is for, while they're being asked;
-- then whether to fill a slot someone left open, then whether to move a
-- questing listing to the zone its leader went to; else it's the player's
-- party when they're in one, otherwise the newest relevant group, or none.
local LfgDrawerModel = {
    NONE = "none",
    NEWEST = "newest",
    PARTY = "party",
    -- The leader is asked what their party is for.
    ASK = "ask",
    -- The player is asked whether to list a party with players outside the
    -- guild.
    GATE = "gate",
    -- Someone left the player's full party: fill the empty slot?
    SLOT = "slot",
    -- The leader of a questing party moved to another zone: update the
    -- listing's zone?
    ZONE = "zone",
}
addon.LfgDrawerModel = LfgDrawerModel

local Model = {}
Model.__index = Model

function LfgDrawerModel.Create()
    return setmetatable({ known = {}, unseen = {}, deferred = {} }, Model)
end

-- A listing as one appearance: a leader listing again later is new again.
local function keyOf(listing)
    return tostring(listing.id) .. "@" .. tostring(listing.listedAt)
end

-- What to show now. facts:
--   groups    LfgBoard:Groups for the current character ({ relevant, ... })
--   party     nil when not in a party, else { label?, kind?, size, maxSize,
--             openRoles?, note?, slotRole? }: the party and its listing, if
--             any; slotRole is the role an open slot would be posted as
--   combat    in combat, a boss encounter or a keystone run
--   instance  in an instance
--   dnd       Do Not Disturb is on
--   slotOpen  a slot opened in the player's party
--   ask       the leader is being asked what their party is for
--   gate      the player is being asked whether to list a party with
--             players outside the guild
--   zoneMove  the zone the leader of a questing listing moved to, while
--             they're being asked whether to move the listing there
--   requests  the Ask to join requests to the player's listing (LfgRequests)
--   requestOf function(id) -> the player's own request to join leader
--             `id`'s listing (LfgBoard:Request), or nil
-- Returns { count, glow = nil | "gold" | "orange", fresh = the relevant
-- listings new since the last Update that may pulse, top = { kind,
-- listing?, request?, party?, zone? }, requests = the requests to the
-- player }.
function Model:Update(facts)
    local relevant = facts.groups and facts.groups.relevant or {}
    local hidden = facts.party ~= nil or facts.combat == true or facts.instance == true or facts.dnd == true
    -- A party or Do Not Disturb means "not now": what appears then never
    -- glows.
    local ignored = facts.party ~= nil or facts.dnd == true
    local current, fresh = {}, {}
    local index
    for index = 1, #relevant do
        local key = keyOf(relevant[index])
        current[key] = true
        if not self.known[key] then
            self.known[key] = true
            if not ignored then
                self.unseen[key] = true
                if hidden then
                    -- Held back in combat or an instance: its pulse (and
                    -- chat line) comes once that's over.
                    self.deferred[key] = true
                else
                    table.insert(fresh, relevant[index])
                end
            end
        elseif self.deferred[key] and not hidden then
            self.deferred[key] = nil
            table.insert(fresh, relevant[index])
        end
    end
    -- What's gone from the board no longer glows.
    local key
    for key in pairs(self.unseen) do
        if not current[key] then
            self.unseen[key] = nil
            self.deferred[key] = nil
        end
    end
    local glow
    if facts.slotOpen then
        glow = "orange"
    elseif not hidden and next(self.unseen) ~= nil then
        glow = "gold"
    end
    local top
    if facts.gate then
        top = { kind = LfgDrawerModel.GATE, party = facts.party }
    elseif facts.ask then
        top = { kind = LfgDrawerModel.ASK, party = facts.party }
    elseif facts.slotOpen and facts.party ~= nil then
        top = { kind = LfgDrawerModel.SLOT, party = facts.party }
    elseif facts.zoneMove ~= nil then
        top = { kind = LfgDrawerModel.ZONE, party = facts.party, zone = facts.zoneMove }
    elseif facts.party ~= nil then
        top = { kind = LfgDrawerModel.PARTY, party = facts.party }
    elseif relevant[1] ~= nil then
        top = { kind = LfgDrawerModel.NEWEST, listing = relevant[1],
            request = facts.requestOf and facts.requestOf(relevant[1].id) or nil }
    else
        top = { kind = LfgDrawerModel.NONE }
    end
    return { count = #relevant, glow = glow, fresh = fresh, top = top, requests = facts.requests or {} }
end

-- The drawer was opened: everything on the board has been seen.
function Model:Seen()
    self.unseen = {}
    self.deferred = {}
end
