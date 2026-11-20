local _, addon = ...

-- Group friends: from the user's own party history (GroupHistory), what tier
-- a player is. Parties count per player, across all of their characters: a
-- party with two of a player's characters counts once, as GroupHistory:Stats
-- does.
--   Grouped   grouped with at least once
--   Frequent  grouped with FREQUENT_PARTIES times or more
--   Top 5     the TOP_SIZE players grouped with most, whatever their counts.
--             Ties go to the most recent party, then to the player key, so
--             the list is always the same. Top 5 wins over Frequent.
-- Frequent and Top 5 get Guild Greet's perks (HasPerks).
--
-- The tiers are worked out once and kept until the history changes (a new
-- party, or characters added to the current one) or `version` does, so a
-- prompt never rescans the whole history. History is never pruned for it.
--
-- Pure: the partition and the way to find a character's player are handed
-- in.
local GroupFriends = {
    GROUPED = "grouped",
    FREQUENT = "frequent",
    TOP = "top5",
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
function GroupFriends.Create(options)
    return setmetatable({
        partition = options.partition,
        playerOf = options.playerOf,
        version = options.version,
    }, Friends)
end

-- Whether `tier` gets Guild Greet's perks: Frequent and Top 5 do.
function GroupFriends.HasPerks(tier)
    return tier == GroupFriends.FREQUENT or tier == GroupFriends.TOP
end

function Friends:player(key)
    local ok, player = pcall(self.playerOf, key)
    if ok and player ~= nil then
        return player
    end
    return key
end

-- Whether the tiers worked out last are still current.
function Friends:current()
    local count, last, characters = self.partition:GroupHistoryMark()
    local version = self.version and self.version() or nil
    local mark = self.mark
    if mark ~= nil and mark.count == count and mark.last == last and mark.characters == characters
        and mark.version == version
    then
        return true
    end
    self.mark = { count = count, last = last, characters = characters, version = version }
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
    local ranked = {}
    local _, stat
    for _, stat in pairs(stats) do
        table.insert(ranked, stat)
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
    local tiers = {}
    for index = 1, #ranked do
        local tier = GroupFriends.GROUPED
        if index <= GroupFriends.TOP_SIZE then
            tier = GroupFriends.TOP
        elseif ranked[index].count >= GroupFriends.FREQUENT_PARTIES then
            tier = GroupFriends.FREQUENT
        end
        tiers[ranked[index].player] = tier
    end
    self.tiers = tiers
end

-- The tier of the player character `key` belongs to: GROUPED, FREQUENT,
-- TOP, or nil when the user never grouped with them.
function Friends:TierOf(key)
    if key == nil then
        return nil
    end
    if not self:current() or self.tiers == nil then
        self:rank()
    end
    return self.tiers[self:player(key)]
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
