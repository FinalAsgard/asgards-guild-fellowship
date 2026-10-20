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
--   rankNames     the game's rank names, the guild master's first
local PromotionPolicy = {}
addon.PromotionPolicy = PromotionPolicy

-- How each kind of item is judged for `key`: true when met, plus the tick
-- record (manual items) when there is one.
PromotionPolicy.STATUS = {
    check = function(inputs, key, item)
        local record = inputs.checks:Record(key, item.id)
        return record ~= nil and record.ticked, record
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
-- where each item is { id, label, kind, met, record }. `highestRank` is
-- the player's highest rank when it's higher than this character's, else
-- nil.
function PromotionPolicy.Evaluate(inputs, key, itemsOf)
    local partition = inputs.partition
    local character = partition:GetCharacter(key)
    if character == nil or not partition:IsInGuild(key) or type(character.rank) ~= "number" or character.rank < 1 then
        return nil
    end
    local rank = character.rank
    local items = itemsOf and itemsOf(rank) or inputs.requirements:Items(rank)
    if items[1] == nil then
        return nil
    end
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
        local judge = PromotionPolicy.STATUS[item.kind]
        local met, record = false, nil
        if judge ~= nil then
            met, record = judge(inputs, key, item)
        end
        table.insert(result.items, { id = item.id, label = item.label, kind = item.kind, met = met == true,
            record = record })
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

-- Every character at a rank with requirements, evaluated: ready ones
-- first, then by rank (the highest first), then by name (`nameOf(key)`).
function PromotionPolicy.List(inputs, nameOf)
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
    local rows = {}
    inputs.partition:EachCharacter(function(key, character)
        if ranks[character.rank] then
            local row = PromotionPolicy.Evaluate(inputs, key, itemsOf)
            if row ~= nil then
                row.name = nameOf and nameOf(key) or key
                table.insert(rows, row)
            end
        end
    end)
    table.sort(rows, function(a, b)
        if a.ready ~= b.ready then
            return a.ready
        end
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        if string.lower(a.name) ~= string.lower(b.name) then
            return string.lower(a.name) < string.lower(b.name)
        end
        return a.key < b.key
    end)
    return rows
end
