local _, addon = ...

-- A local record of the parties this player was in with guildmates, any
-- party, not just the Group Finder's: { at, characters = { key, ... },
-- dungeon? } per party, kept in the guild partition and never synced. A
-- party lasts while it keeps someone from the last look at it: guildmates
-- who join are added to its entry, and one swapped for another doesn't
-- make it a new party. Only a party with nobody from the last look (or one
-- after the player was out of any party) starts a new entry. Reloading
-- inside the same party doesn't count it again. A dungeon learned later
-- (entering the instance) is added to the entry. It answers how often, and
-- when last, this player grouped with any of another player's characters.
--
-- Pure: the partition and the party's facts are handed in.
local GroupHistory = {
    -- A reload within this long, in the same party, isn't a new party.
    SAME_PARTY_SECONDS = 6 * 60 * 60,
}
addon.GroupHistory = GroupHistory

local History = {}
History.__index = History

function GroupHistory.Create(partition)
    return setmetatable({ partition = partition }, History)
end

local function setOf(keys)
    local set = {}
    local index
    for index = 1, #keys do
        set[keys[index]] = true
    end
    return set
end

local function sorted(keys)
    local list = {}
    local key
    for key in pairs(setOf(keys)) do
        table.insert(list, key)
    end
    table.sort(list)
    return list
end

-- Whether `a` and `b` share any key.
local function overlaps(a, b)
    local set = setOf(b)
    local index
    for index = 1, #a do
        if set[a[index]] then
            return true
        end
    end
    return false
end

-- The party now holds the guild characters `keys` (this player's own left
-- out), at `now`, in `dungeon` (a name, when known). Records a new entry,
-- adds to the current one, or does nothing. Returns the entry recorded or
-- changed, or nil.
function History:OnParty(keys, now, dungeon)
    keys = sorted(keys or {})
    local firstLook = not self.seen
    self.seen = true
    local previous = self.observed
    if keys[1] == nil then
        self.current = nil
        self.observed = nil
        return nil
    end
    self.observed = keys
    local entry = self.current
    if entry ~= nil and not overlaps(keys, previous or entry.characters) then
        entry = nil
    end
    -- After a reload, the last party recorded, if it was recent and shares
    -- someone with this one.
    if entry == nil and firstLook then
        local entries = self.partition:GetGroupHistory()
        local last = entries[#entries]
        if last ~= nil and now - last.at < GroupHistory.SAME_PARTY_SECONDS and overlaps(keys, last.characters) then
            entry = last
        end
    end
    if entry == nil then
        entry = { at = now, characters = keys, dungeon = dungeon }
        self.partition:AddGroupHistory(entry)
        self.current = entry
        return entry
    end
    self.current = entry
    -- Everyone who was ever in it stays in the entry.
    local changed = false
    local held = setOf(entry.characters)
    local index
    for index = 1, #keys do
        if not held[keys[index]] then
            changed = true
            table.insert(entry.characters, keys[index])
        end
    end
    if changed then
        entry.characters = sorted(entry.characters)
    end
    if entry.dungeon == nil and dungeon ~= nil then
        entry.dungeon = dungeon
        changed = true
    end
    return changed and entry or nil
end

-- How many recorded parties included any of `keys` (one player's
-- characters), and when the last one was: count, at (nil when none).
function History:Stats(keys)
    local wanted = setOf(keys or {})
    local count, last = 0, nil
    local entries = self.partition:GetGroupHistory()
    local index
    for index = 1, #entries do
        local entry = entries[index]
        local characterIndex
        for characterIndex = 1, #entry.characters do
            if wanted[entry.characters[characterIndex]] then
                count = count + 1
                if last == nil or entry.at > last then
                    last = entry.at
                end
                break
            end
        end
    end
    return count, last
end

-- "Grouped together 3 times, last on 2026-10-12", or nil when never.
function History:Line(keys, formatDate)
    local count, last = self:Stats(keys)
    if count == 0 then
        return nil
    end
    return "Grouped together " .. count .. (count == 1 and " time" or " times") .. ", last on " .. formatDate(last)
end
