local _, addon = ...

-- Group friends: from the user's own party history (GroupHistory), what tier
-- a player is. Parties count per player, across all of their characters: a
-- party with two of a player's characters counts once, as GroupHistory:Stats
-- does.
--   Grouped   grouped with at least once
--   Frequent  grouped with FREQUENT_PARTIES times or more
--   Top 5     the TOP_SIZE players grouped with most, whatever their counts,
--             skipping pinned Friends. Ties go to the most recent party,
--             then to the player key, so the list is always the same. Top 5
--             wins over Frequent.
--   Friend    a player the user pinned in a Friend slot (any of their
--             characters), grouped with or not; never Top 5 or Frequent.
-- Frequent, Top 5 and Friend get Guild Greet's perks (HasPerks).
--
-- The tiers are worked out once and kept until the history changes (a new
-- party, or characters added to the current one), the Friend slots do, or
-- `version` does, so a prompt never rescans the whole history. History is
-- never pruned for it.
--
-- Pure: the partition and the way to find a character's player are handed
-- in.
local GroupFriends = {
    GROUPED = "grouped",
    FREQUENT = "frequent",
    TOP = "top5",
    FRIEND = "friend",
    FREQUENT_PARTIES = 4,
    TOP_SIZE = 5,
}
addon.GroupFriends = GroupFriends

local Friends = {}
Friends.__index = Friends

-- options:
--   partition  the guild partition holding the group history
--   playerOf   function(key) -> the player a character belongs to, or nil
--              (the character is then its own player)
--   version    function() -> anything that changes when who belongs to which
--              player may have. Optional.
--   friends    function() -> the character keys pinned in the Friend slots.
--              Optional; without it nobody is a Friend.
function GroupFriends.Create(options)
    return setmetatable({
        partition = options.partition,
        playerOf = options.playerOf,
        version = options.version,
        friends = options.friends,
    }, Friends)
end

-- Whether `tier` gets Guild Greet's perks: Frequent, Top 5 and Friend do.
function GroupFriends.HasPerks(tier)
    return tier == GroupFriends.FREQUENT or tier == GroupFriends.TOP or tier == GroupFriends.FRIEND
end

-- Whether `tier` gets the star on the LFG page: Top 5 and Friend do.
function GroupFriends.IsStarred(tier)
    return tier == GroupFriends.TOP or tier == GroupFriends.FRIEND
end

function Friends:player(key)
    local ok, player = pcall(self.playerOf, key)
    if ok and player ~= nil then
        return player
    end
    return key
end

-- The pinned Friend keys, or none when they can't be read.
function Friends:pinned()
    if self.friends == nil then
        return {}
    end
    local ok, keys = pcall(self.friends)
    local pinned = {}
    local index
    for index = 1, ok and type(keys) == "table" and #keys or 0 do
        if type(keys[index]) == "string" then
            table.insert(pinned, keys[index])
        end
    end
    return pinned
end

-- Whether the tiers worked out last are still current.
function Friends:current()
    local count, last, characters = self.partition:GroupHistoryMark()
    local version = self.version and self.version() or nil
    local pinned = table.concat(self:pinned(), "\n")
    local mark = self.mark
    if mark ~= nil and mark.count == count and mark.last == last and mark.characters == characters
        and mark.version == version and mark.pinned == pinned
    then
        return true
    end
    self.mark = { count = count, last = last, characters = characters, version = version, pinned = pinned }
    return false
end

-- Works out every player's tier from the whole history.
function Friends:rank()
    local stats = {}
    local entries = self.partition:GetGroupHistory()
    local index
    for index = 1, #entries do
        local entry = entries[index]
        local counted = {}
        local characterIndex
        for characterIndex = 1, #entry.characters do
            local player = self:player(entry.characters[characterIndex])
            if not counted[player] then
                counted[player] = true
                local stat = stats[player]
                if stat == nil then
                    stat = { player = player, count = 0, last = entry.at }
                    stats[player] = stat
                end
                stat.count = stat.count + 1
                if entry.at > stat.last then
                    stat.last = entry.at
                end
            end
        end
    end
    -- Pinned Friends are FRIEND, and the ranking for Top 5 skips them.
    local tiers = {}
    local pinned = self:pinned()
    for index = 1, #pinned do
        tiers[self:player(pinned[index])] = GroupFriends.FRIEND
    end
    local ranked = {}
    local _, stat
    for _, stat in pairs(stats) do
        if tiers[stat.player] == nil then
            table.insert(ranked, stat)
        end
    end
    table.sort(ranked, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        if a.last ~= b.last then
            return a.last > b.last
        end
        return tostring(a.player) < tostring(b.player)
    end)
    local top = {}
    for index = 1, #ranked do
        local tier = GroupFriends.GROUPED
        if index <= GroupFriends.TOP_SIZE then
            tier = GroupFriends.TOP
            table.insert(top, { player = ranked[index].player, count = ranked[index].count,
                last = ranked[index].last })
        elseif ranked[index].count >= GroupFriends.FREQUENT_PARTIES then
            tier = GroupFriends.FREQUENT
        end
        tiers[ranked[index].player] = tier
    end
    self.top = top
    self.tiers = tiers
    self.stats = stats
end

-- Works the tiers out again when they aren't current.
function Friends:refresh()
    if not self:current() or self.tiers == nil then
        self:rank()
    end
end

-- The tier of the player character `key` belongs to: GROUPED, FREQUENT,
-- TOP, FRIEND, or nil when the user never grouped with them and didn't pin
-- them.
function Friends:TierOf(key)
    if key == nil then
        return nil
    end
    self:refresh()
    return self.tiers[self:player(key)]
end

-- The Top 5 in order (Most grouped with on the Friends page): { { player,
-- count, last } }, the players grouped with most who aren't pinned Friends.
-- `player` is what playerOf gives (or the key, for a character with no
-- player).
function Friends:MostGrouped()
    self:refresh()
    local list = {}
    local index
    for index = 1, #self.top do
        local entry = self.top[index]
        list[index] = { player = entry.player, count = entry.count, last = entry.last }
    end
    return list
end

-- How many parties the user was in with the player character `key`
-- belongs to, and when the last was: count, at (nil when never).
function Friends:StatsOf(key)
    if key == nil then
        return 0, nil
    end
    self:refresh()
    local stat = self.stats[self:player(key)]
    if stat == nil then
        return 0, nil
    end
    return stat.count, stat.last
end

-- For each tier, the character most recently grouped with whose player is
-- in it, among those `accept(key)` allows: { [tier] = key }. A tier nobody
-- is in is left out. For the Dev build's test prompts.
function Friends:Samples(accept)
    local samples = {}
    local entries = self.partition:GetGroupHistory()
    local index
    for index = #entries, 1, -1 do
        local characters = entries[index].characters
        local characterIndex
        for characterIndex = 1, #characters do
            local key = characters[characterIndex]
            local tier = self:TierOf(key)
            if tier ~= nil and samples[tier] == nil and accept(key) then
                samples[tier] = key
            end
        end
    end
    return samples
end
