local _, addon = ...

-- A local record of the parties this player was in with guildmates, any
-- party, not just the Group Finder's: { at, characters = { key, ... },
-- dungeon? } per party, kept in the guild partition and never synced. A
-- party is recorded once: guildmates joining it later are added to its
-- entry, and only a party that isn't the same one (someone left and others
-- came, or the party broke up) starts a new entry. Reloading inside the same
-- party doesn't count it again. It answers how often, and when last, this
-- player grouped with any of another player's characters.
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

-- Whether every key of `small` is in `large`.
local function within(small, large)
    local set = setOf(large)
    local index
    for index = 1, #small do
        if not set[small[index]] then
            return false
        end
    end
    return true
end

-- The party now holds the guild characters `keys` (this player's own left
-- out), at `now`, in `dungeon` (a name, when known). Records a new entry,
-- grows the current one, or does nothing. Returns the entry recorded or
-- grown, or nil.
function History:OnParty(keys, now, dungeon)
    keys = sorted(keys or {})
    local firstLook = not self.seen
    self.seen = true
    if keys[1] == nil then
        self.current = nil
        return nil
    end
    local entries = self.partition:GetGroupHistory()
    local last = entries[#entries]
    -- The party this session last saw. On the session's first look (after
    -- a reload), the last one recorded, if it was recent.
    local current = self.current
    if firstLook and last ~= nil and now - last.at < GroupHistory.SAME_PARTY_SECONDS then
        current = last
    end
    if current ~= nil and current == last then
        if within(keys, last.characters) then
            self.current = last
            return nil
        end
        -- Still the same party when nobody it had has left: more joined.
        if within(last.characters, keys) then
            last.characters = keys
            last.dungeon = last.dungeon or dungeon
            self.current = last
            return last
        end
    end
    local entry = { at = now, characters = keys, dungeon = dungeon }
    self.partition:AddGroupHistory(entry)
    self.current = entry
    return entry
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
