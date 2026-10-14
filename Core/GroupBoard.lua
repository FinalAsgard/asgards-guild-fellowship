local _, addon = ...

-- The groups other guildmates are forming, as their add-ons announce them
-- (GroupFinderProtocol.TYPE_GROUP): one per organizer, until it ends or
-- nothing is heard of it for STALE_SECONDS (an organizer re-announces it
-- every GROUP_RESEND_SECONDS). Also the offer this player made to fill a
-- slot in each, and what became of it. Pure: messages and times are
-- handed in.
local GroupBoard = {
    STALE_SECONDS = 150,
    -- A group is near a level within this many levels of its range.
    NEAR_LEVELS = 2,
    -- How long an offer waits for the organizer's answer.
    OFFER_SECONDS = 120,
    SENT = "sent",
    ACCEPTED = "accepted",
    DECLINED = "declined",
    EXPIRED = "expired",
}
addon.GroupBoard = GroupBoard

local Board = {}
Board.__index = Board

function GroupBoard.Create()
    return setmetatable({ groups = {}, offers = {} }, Board)
end

local function bareName(name)
    return string.match(name or "", "^([^%-]+)") or name
end

-- Organizer `organizer` (their character key, named `sender`) announced
-- `message` at `now`.
function Board:OnGroup(message, organizer, sender, now)
    local slots = {}
    local index
    for index = 1, #message.s do
        local slot = message.s[index]
        slots[index] = {
            role = slot.r, name = slot.n, level = slot.l, key = slot.k, classToken = slot.c,
            coming = slot.w == true,
        }
    end
    self.groups[organizer] = {
        id = organizer,
        organizer = organizer,
        label = bareName(sender) or organizer,
        dungeon = { name = message.dn, minLevel = message.lo, maxLevel = message.hi },
        slots = slots,
        at = now,
    }
end

-- Organizer `organizer`'s group ended.
function Board:OnEnd(organizer)
    self.groups[organizer] = nil
    self.offers[organizer] = nil
end

-- The group organizer `id` is forming, unless it's gone stale by `now`.
function Board:Get(id, now)
    local group = id ~= nil and self.groups[id] or nil
    if group == nil or (type(now) == "number" and now - group.at >= GroupBoard.STALE_SECONDS) then
        return nil
    end
    return group
end

-- How many of `group`'s slots are filled.
function GroupBoard.Filled(group)
    local filled = 0
    local index
    for index = 1, #group.slots do
        if group.slots[index].name ~= nil then
            filled = filled + 1
        end
    end
    return filled
end

-- Whether `level` is within NEAR_LEVELS of `group`'s range; an unknown
-- level is near every group.
function GroupBoard.Near(group, level)
    return type(level) ~= "number"
        or (level >= group.dungeon.minLevel - GroupBoard.NEAR_LEVELS
            and level <= group.dungeon.maxLevel + GroupBoard.NEAR_LEVELS)
end

-- The groups being formed at `now`: those near `level` first, then by
-- their dungeon's range, then by organizer.
function Board:Groups(level, now)
    local list = {}
    local id
    for id in pairs(self.groups) do
        local group = self:Get(id, now)
        if group ~= nil then
            table.insert(list, group)
        end
    end
    table.sort(list, function(a, b)
        local nearA, nearB = GroupBoard.Near(a, level), GroupBoard.Near(b, level)
        if nearA ~= nearB then
            return nearA
        end
        if a.dungeon.minLevel ~= b.dungeon.minLevel then
            return a.dungeon.minLevel < b.dungeon.minLevel
        end
        if a.label ~= b.label then
            return a.label < b.label
        end
        return a.id < b.id
    end)
    return list
end

-- The player offered `option` ({ role, key, name, level }) to group `id`
-- as offer `offerId`, at `now`.
function Board:Offer(id, offerId, option, now)
    self.offers[id] = {
        id = offerId, role = option.role, key = option.key, name = option.name, state = GroupBoard.SENT, at = now,
    }
end

-- The player's offer to group `id`, its state as of `now`, or nil.
function Board:OfferFor(id, now)
    local offer = self.offers[id]
    if offer ~= nil and offer.state == GroupBoard.SENT and type(now) == "number"
        and now - offer.at >= GroupBoard.OFFER_SECONDS
    then
        offer.state = GroupBoard.EXPIRED
    end
    return offer
end

-- Organizer `organizer` answered offer `offerId`. Returns the offer, or
-- nil when it isn't the one waiting.
function Board:OnOfferAnswer(offerId, organizer, accepted)
    local offer = self.offers[organizer]
    if offer == nil or offer.id ~= offerId or offer.state ~= GroupBoard.SENT then
        return nil
    end
    offer.state = accepted and GroupBoard.ACCEPTED or GroupBoard.DECLINED
    return offer
end
