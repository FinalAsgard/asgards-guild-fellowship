local _, addon = ...

-- The promotion rules engine: for each character, the next rank, each
-- requirement's status, progress, whether it's ready, and its player's
-- highest rank. Pure: the caller passes everything in.
--
-- inputs:
--   partition     the guild's FellowshipStore partition (characters, their
--                 ranks and players, who is in the guild)
--   requirements  the guild's RankRequirements
--   checks        the guild's PromotionChecks
--   dates         the guild's MembershipDates (for the automated kinds)
--   now           the server time now
--   rankNames     the game's rank names, the guild master's first
local PromotionPolicy = {
    DAY = 24 * 60 * 60,
}
addon.PromotionPolicy = PromotionPolicy

local function days(inputs, time)
    return math.max(0, math.floor(((inputs.now or time) - time) / PromotionPolicy.DAY))
end

-- A time check against `record` (a join or rank-since date, or an earliest
-- join): before tracking passes any N; an approximate date says so.
local function daysCheck(inputs, record, n, unknown)
    if record == nil then
        return false, unknown
    end
    if record.beforeTracking or record.source == addon.MembershipDates.BEFORE_TRACKING then
        return true, "before tracking"
    end
    local count = days(inputs, record.time)
    local approximate = record.approximate or record.source == addon.MembershipDates.FIRST_SEEN
        or record.source == addon.MembershipDates.SEEN
    local text
    if count >= n then
        text = count .. " days (needs " .. n .. ")"
    else
        text = count .. " of " .. n .. " days"
    end
    return count >= n, text .. (approximate and " (approx.)" or "")
end

-- The characters of `key`'s player now in the guild (just `key` when it
-- has no player).
local function playerCharacters(partition, key, character)
    if character.player == nil then
        return { key }
    end
    local keys = {}
    local all = partition:CharactersOf(character.player)
    local index
    for index = 1, #all do
        if partition:IsInGuild(all[index]) then
            table.insert(keys, all[index])
        end
    end
    if keys[1] == nil then
        keys[1] = key
    end
    return keys
end

-- How each kind of item is judged for `key` (whose record is `character`):
-- true when met, and for an automated kind the detail ("5 of 7 days").
-- Manual kinds are met by an officer's tick; any failed automated kind can
-- be overridden by one (see Evaluate).
PromotionPolicy.STATUS = {
    check = function(inputs, key, item)
        local record = inputs.checks:Record(key, item.id)
        return record ~= nil and record.ticked
    end,
    ["char-guild-days"] = function(inputs, key, item)
        local joined = inputs.dates and inputs.dates:Joined(key)
        return daysCheck(inputs, joined, item.n, "join date unknown")
    end,
    ["player-guild-days"] = function(inputs, key, item, character)
        local earliest = inputs.dates and inputs.dates:EarliestJoin(playerCharacters(inputs.partition, key, character))
        return daysCheck(inputs, earliest, item.n, "join date unknown")
    end,
    ["rank-days"] = function(inputs, key, item, character)
        local since = inputs.dates and inputs.dates:RankSince(key, character.rank)
        return daysCheck(inputs, since, item.n, "rank date unknown")
    end,
    level = function(inputs, key, item, character)
        local level = character.level
        if type(level) ~= "number" then
            return false, "level unknown"
        end
        if level >= item.n then
            return true, "level " .. level .. " (needs " .. item.n .. ")"
        end
        return false, "level " .. level .. " of " .. item.n
    end,
    -- Player-wide: any of the player's characters in the guild ever heard
    -- on add-on sync.
    addon = function(inputs, key, item, character)
        local heard = inputs.dates and inputs.dates:LastHeard(playerCharacters(inputs.partition, key, character))
        if heard == nil then
            return false, "add-on not seen"
        end
        local count = days(inputs, heard)
        local text = count == 0 and "seen today" or ("seen " .. count .. (count == 1 and " day ago" or " days ago"))
        return true, text
    end,
}
PromotionPolicy.STATUS["check-note"] = PromotionPolicy.STATUS.check

-- The highest rank (lowest index) among `playerId`'s characters in the
-- guild, or nil.
function PromotionPolicy.HighestRank(partition, playerId)
    local best
    local keys = partition:CharactersOf(playerId)
    local index
    for index = 1, #keys do
        local character = partition:GetCharacter(keys[index])
        if character ~= nil and type(character.rank) == "number" and partition:IsInGuild(keys[index])
            and (best == nil or character.rank < best)
        then
            best = character.rank
        end
    end
    return best
end

-- One character's promotion status, or nil when it isn't in the guild,
-- its rank is the top one (nothing above it), or its rank has no
-- requirements:
--   { key, rank, rankName, nextRank, nextRankName, items, met, total, ready,
--     highestRank, highestRankName }
-- where each item is { id, label, kind, automated, met, detail,
-- overridden, record }: `record` is the officer's tick (or override) when
-- there is one, `detail` an automated item's status in words, and
-- `overridden` true when an officer's override is what meets a failed
-- automated item. `highestRank` is the player's highest rank when it's
-- higher than this character's, else nil.
-- `key`'s record and its rank's items, or nil when it has no checklist.
local function checklistOf(inputs, key, itemsOf)
    local partition = inputs.partition
    local character = partition:GetCharacter(key)
    if character == nil or not partition:IsInGuild(key) or type(character.rank) ~= "number" or character.rank < 1 then
        return nil
    end
    local items = itemsOf and itemsOf(character.rank) or inputs.requirements:Items(character.rank)
    if items[1] == nil then
        return nil
    end
    return character, items
end

-- One item's status for `key`: met, detail, the officer's record, whether
-- the kind is automated, and whether an override is what meets it.
local function judgeItem(inputs, key, item, character)
    local judge = PromotionPolicy.STATUS[item.kind]
    local met, detail = false, nil
    if judge ~= nil then
        met, detail = judge(inputs, key, item, character)
    end
    met = met == true
    local record = inputs.checks:Record(key, item.id)
    local automated = addon.RankRequirements.IsAutomated(item.kind)
    local overridden = false
    if automated and not met and record ~= nil and record.ticked then
        met, overridden = true, true
    end
    return met, detail, record, automated, overridden
end

-- Just enough of `key`'s status to tell whether it's ready (see
-- ReadySet): { key, rank, met, total, ready }, or nil as for Evaluate.
function PromotionPolicy.Summarize(inputs, key, itemsOf)
    local character, items = checklistOf(inputs, key, itemsOf)
    if character == nil then
        return nil
    end
    local met = 0
    local index
    for index = 1, #items do
        if judgeItem(inputs, key, items[index], character) then
            met = met + 1
        end
    end
    return { key = key, rank = character.rank, met = met, total = #items, ready = met == #items }
end

function PromotionPolicy.Evaluate(inputs, key, itemsOf)
    local partition = inputs.partition
    local character, items = checklistOf(inputs, key, itemsOf)
    if character == nil then
        return nil
    end
    local rank = character.rank
    local names = inputs.rankNames or {}
    local result = {
        key = key,
        rank = rank,
        rankName = names[rank + 1] or ("Rank " .. rank),
        nextRank = rank - 1,
        nextRankName = names[rank] or ("Rank " .. (rank - 1)),
        items = {},
        met = 0,
        total = #items,
    }
    local index
    for index = 1, #items do
        local item = items[index]
        local met, detail, record, automated, overridden = judgeItem(inputs, key, item, character)
        table.insert(result.items, { id = item.id, label = item.label, kind = item.kind, automated = automated,
            met = met, detail = detail, overridden = overridden, record = record })
        if met then
            result.met = result.met + 1
        end
    end
    result.ready = result.met == result.total
    local highest = PromotionPolicy.HighestRank(partition, character.player)
    if highest ~= nil and highest < rank then
        result.highestRank = highest
        result.highestRankName = names[highest + 1] or ("Rank " .. highest)
    end
    return result
end

-- Calls `visit(key, character, itemsOf)` for each character at a rank with
-- requirements; `itemsOf(rank)` reads each rank's items once.
local function eachCandidate(inputs, visit)
    local ranks = {}
    local itemsByRank = {}
    local withItems = inputs.requirements:Ranks()
    local index
    for index = 1, #withItems do
        ranks[withItems[index]] = true
    end
    local function itemsOf(rank)
        if itemsByRank[rank] == nil then
            itemsByRank[rank] = inputs.requirements:Items(rank)
        end
        return itemsByRank[rank]
    end
    inputs.partition:EachCharacter(function(key, character)
        if ranks[character.rank] then
            visit(key, character, itemsOf)
        end
    end)
end

-- The characters who meet every requirement, as a set of keys.
function PromotionPolicy.ReadySet(inputs)
    local ready = {}
    eachCandidate(inputs, function(key, character, itemsOf)
        local summary = PromotionPolicy.Summarize(inputs, key, itemsOf)
        if summary ~= nil and summary.ready then
            ready[key] = true
        end
    end)
    return ready
end
