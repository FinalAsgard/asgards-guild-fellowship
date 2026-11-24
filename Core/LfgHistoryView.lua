local _, addon = ...

-- The Guild LFG Board's History tab: the player's own parties from
-- GroupHistory, newest first, PAGE_SIZE at a time (Show more adds the
-- next PAGE_SIZE). Each party has its time, its dungeon or zone when
-- known, and its guildmates with their group-friend tier. Pure: the
-- entries and the lookups are handed in.
local LfgHistoryView = {
    PAGE_SIZE = 20,
}
addon.LfgHistoryView = LfgHistoryView

local View = {}
View.__index = View

function LfgHistoryView.Create()
    return setmetatable({ shown = LfgHistoryView.PAGE_SIZE }, View)
end

-- Show more: the next PAGE_SIZE parties too.
function View:More()
    self.shown = self.shown + LfgHistoryView.PAGE_SIZE
end

-- Back to the first PAGE_SIZE.
function View:Reset()
    self.shown = LfgHistoryView.PAGE_SIZE
end

-- What to show of `entries` (GroupHistory's { at, characters, dungeon? }).
-- `member(key)` gives a guildmate's { name, whisper, classToken? }, or nil
-- for one no longer known (left out); `tierOf(key)` their GroupFriends
-- tier, or nil. Returns { parties = { { at, place?, members = { { key,
-- name, whisper, classToken?, tier?, friend } } } }, more = whether older
-- parties are left, total }.
function View:Page(entries, member, tierOf)
    entries = entries or {}
    local order = {}
    local index
    for index = 1, #entries do
        order[index] = index
    end
    -- Newest first; the same time keeps the later-recorded first.
    table.sort(order, function(a, b)
        local atA, atB = entries[a].at or 0, entries[b].at or 0
        if atA ~= atB then
            return atA > atB
        end
        return a > b
    end)
    local parties = {}
    for index = 1, math.min(self.shown, #order) do
        local entry = entries[order[index]]
        local members = {}
        local characterIndex
        for characterIndex = 1, #(entry.characters or {}) do
            local key = entry.characters[characterIndex]
            local known = member and member(key) or nil
            if known ~= nil then
                local tier = tierOf and tierOf(key) or nil
                table.insert(members, { key = key, name = known.name, whisper = known.whisper,
                    classToken = known.classToken, tier = tier,
                    friend = tier ~= nil and addon.GroupFriends ~= nil and addon.GroupFriends.HasPerks(tier) })
            end
        end
        parties[index] = { at = entry.at, place = entry.dungeon, members = members }
    end
    return { parties = parties, more = #order > self.shown, total = #order }
end
