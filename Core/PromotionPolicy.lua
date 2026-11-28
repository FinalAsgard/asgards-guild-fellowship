local _, addon = ...

-- The promotion rules engine: for each player, one rank-up profile (on its
-- highest-ranked character, see ProfileOf) with the next rank, each
-- requirement's status, progress, and whether it's ready; and for each
-- character, the rank to promote it to so it matches its player's other
-- characters. Pure: the caller passes everything in.
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
-- join): before tracking passes any N; an approximate date says so. The
-- fourth value is the days still to go, nil when met or unknown (an
-- approximate date counts from that date).
local function daysCheck(inputs, record, n, unknown)
    if record == nil then
        return false, unknown, "unknown"
    end
    if record.beforeTracking or record.source == addon.MembershipDates.BEFORE_TRACKING then
        return true, "before tracking", "before tracking"
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
    return count >= n, text .. (approximate and " (approx.)" or ""), (approximate and "≈" or "") .. count .. " d",
        count < n and (n - count) or nil
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
-- true when met, and for an automated kind the detail ("5 of 7 days") and
-- the detail in short, for a grid cell ("5 d", "≈44 d", "level 76"); a
-- time kind also gives the days still to go (see daysCheck).
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
            return false, "level unknown", "unknown"
        end
        if level >= item.n then
            return true, "level " .. level .. " (needs " .. item.n .. ")", "level " .. level
        end
        return false, "level " .. level .. " of " .. item.n, "level " .. level
    end,
    -- Player-wide: any of the player's characters in the guild ever heard
    -- on add-on sync.
    addon = function(inputs, key, item, character)
        local heard = inputs.dates and inputs.dates:LastHeard(playerCharacters(inputs.partition, key, character))
        if heard == nil then
            return false, "add-on not seen", "not seen"
        end
        local count = days(inputs, heard)
        local text = count == 0 and "seen today" or ("seen " .. count .. (count == 1 and " day ago" or " days ago"))
        return true, text, count == 0 and "seen today" or ("seen " .. count .. " d ago")
    end,
    -- Player-wide: the player's Discord name (the newest any of its
    -- characters set) isn't empty.
    discord = function(inputs, key, item, character)
        local partition = inputs.partition
        local name
        if character.player ~= nil then
            name = partition:PlayerProfileText(character.player, "discord")
        else
            name = partition:GetProfileText(key, "discord")
        end
        if type(name) ~= "string" or not string.find(name, "%S") then
            return false, "not set", "not set"
        end
        return true, name, name
    end,
}
PromotionPolicy.STATUS["check-note"] = PromotionPolicy.STATUS.check

-- The highest rank (lowest index) among `playerId`'s characters in the
-- guild, or nil.
function PromotionPolicy.HighestRank(partition, playerId)
    local _, rank = PromotionPolicy.HighestCharacter(partition, playerId)
    return rank
end

-- The character of `playerId`'s in the guild with the highest rank, and
-- that rank, or nil. On a tie, the player's main (CharactersOf lists it
-- first), else the first by key.
function PromotionPolicy.HighestCharacter(partition, playerId)
    local bestKey, best
    local keys = partition:CharactersOf(playerId)
    local index
    for index = 1, #keys do
        local key = keys[index]
        local character = partition:GetCharacter(key)
        if character ~= nil and type(character.rank) == "number" and partition:IsInGuild(key)
            and (best == nil or character.rank < best)
        then
            bestKey, best = key, character.rank
        end
    end
    return bestKey, best
end

-- The character that holds `key`'s player's rank-up profile: the player's
-- highest-ranked character in the guild (see HighestCharacter), or `key`
-- itself when it has no player. A player has one checklist, its ticks and
-- snooze kept on that character; the others follow it ("Promote to
-- match").
function PromotionPolicy.ProfileOf(partition, key)
    local character = partition:GetCharacter(key)
    if character == nil or character.player == nil then
        return key
    end
    return (PromotionPolicy.HighestCharacter(partition, character.player)) or key
end

-- One character's promotion status, or nil when it isn't in the guild,
-- doesn't hold its player's profile (see ProfileOf), its rank is the top
-- one (nothing above it), or its rank has no requirements:
--   { key, rank, rankName, nextRank, nextRankName, items, met, total, ready,
--     timeMet, remaining }
-- where each item is { id, label, kind, automated, met, detail, short,
-- overridden, record, remaining }: `record` is the officer's tick (or
-- override) when there is one, `detail` an automated item's status in
-- words, `short` the same for a grid cell, `remaining` a time item's days
-- still to go (nil when met or unknown), and
-- `overridden` true when an officer's override is what meets a failed
-- automated item. The status's `remaining` is the most days any time item
-- still has to go: the days until its time is met, nil when none is open
-- with a known date.
-- `key`'s record and its rank's items, or nil when it has no checklist.
local function checklistOf(inputs, key, itemsOf)
    local partition = inputs.partition
    local character = partition:GetCharacter(key)
    if character == nil or not partition:IsInGuild(key) or type(character.rank) ~= "number" or character.rank < 1
        or PromotionPolicy.ProfileOf(partition, key) ~= key
    then
        return nil
    end
    local items = itemsOf and itemsOf(character.rank) or inputs.requirements:Items(character.rank)
    if items[1] == nil then
        return nil
    end
    return character, items
end

-- One item's status for `key`: met, detail, the officer's record, whether
-- the kind is automated, whether an override is what meets it, the detail
-- in short, and a time item's days still to go.
local function judgeItem(inputs, key, item, character)
    local judge = PromotionPolicy.STATUS[item.kind]
    local met, detail, short, remaining = false, nil, nil, nil
    if judge ~= nil then
        met, detail, short, remaining = judge(inputs, key, item, character)
    end
    met = met == true
    local record = inputs.checks:Record(key, item.id)
    local automated = addon.RankRequirements.IsAutomated(item.kind)
    local overridden = false
    if automated and not met and record ~= nil and record.ticked then
        met, overridden = true, true
    end
    if met then
        remaining = nil
    end
    return met, detail, record, automated, overridden, short or detail, remaining
end

-- The time kinds: when a rank has any, a character whose every one is met
-- is due a promotion check (see TimeMetSet).
PromotionPolicy.TIME_KINDS = {
    ["char-guild-days"] = true,
    ["player-guild-days"] = true,
    ["rank-days"] = true,
}

-- Just enough of `key`'s status to tell whether it's ready (see
-- ReadySet) and whether its time is up (see TimeMetSet): { key, rank,
-- met, total, ready, timeMet }, or nil as for Evaluate. `timeMet` is true
-- when its rank has a time item and every one is met.
function PromotionPolicy.Summarize(inputs, key, itemsOf)
    local character, items = checklistOf(inputs, key, itemsOf)
    if character == nil then
        return nil
    end
    local met = 0
    local timeItems, timeMet = 0, 0
    local index
    for index = 1, #items do
        local item = items[index]
        local itemMet = judgeItem(inputs, key, item, character)
        if itemMet then
            met = met + 1
        end
        if PromotionPolicy.TIME_KINDS[item.kind] then
            timeItems = timeItems + 1
            if itemMet then
                timeMet = timeMet + 1
            end
        end
    end
    return { key = key, rank = character.rank, met = met, total = #items, ready = met == #items,
        timeMet = timeItems > 0 and timeMet == timeItems }
end

function PromotionPolicy.Evaluate(inputs, key, itemsOf)
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
    local timeItems, timeMet = 0, 0
    -- An unmet time check whose date isn't known: no countdown, since the
    -- others' wait isn't the whole of it.
    local unknownWait = false
    local index
    for index = 1, #items do
        local item = items[index]
        local met, detail, record, automated, overridden, short, remaining = judgeItem(inputs, key, item, character)
        if PromotionPolicy.TIME_KINDS[item.kind] and not met and remaining == nil then
            unknownWait = true
        end
        table.insert(result.items, { id = item.id, label = item.label, kind = item.kind, automated = automated,
            met = met, detail = detail, short = short, overridden = overridden, record = record,
            remaining = remaining })
        if remaining ~= nil and (result.remaining == nil or remaining > result.remaining) then
            result.remaining = remaining
        end
        if met then
            result.met = result.met + 1
        end
        if PromotionPolicy.TIME_KINDS[item.kind] then
            timeItems = timeItems + 1
            if met then
                timeMet = timeMet + 1
            end
        end
    end
    result.ready = result.met == result.total
    result.timeMet = timeItems > 0 and timeMet == timeItems
    if unknownWait then
        result.remaining = nil
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

-- Whether alts are matched to `rank`: the rank's "Alts should match this
-- rank" setting.
local function matchesAlts(inputs, rank)
    return inputs.requirements:MatchesAlts(rank)
end

-- The rank `key` should be promoted to so it matches its player's other
-- characters, or nil. The ceiling is the player's highest rank in the
-- guild, or the rank just below the guild master's when that's it (a guild
-- has one guild master); the target is the highest rank at or below the
-- ceiling, above `key`'s own, that alts are matched to. It doesn't depend on
-- whether `key`'s rank has requirements.
-- `highestOf(player)`, when given, is the player's highest rank (MatchSet
-- reads each player's once).
local function matchTarget(inputs, key, highestOf)
    local partition = inputs.partition
    local character = partition:GetCharacter(key)
    if character == nil or character.player == nil or not partition:IsInGuild(key)
        or type(character.rank) ~= "number"
    then
        return nil
    end
    local ceiling = highestOf(character.player)
    if ceiling == nil then
        return nil
    end
    ceiling = math.max(ceiling, 1)
    local rank
    for rank = ceiling, character.rank - 1 do
        if matchesAlts(inputs, rank) then
            return rank
        end
    end
    return nil
end

function PromotionPolicy.MatchTarget(inputs, key)
    return matchTarget(inputs, key, function(player)
        return PromotionPolicy.HighestRank(inputs.partition, player)
    end)
end

-- Every character in the guild with a match target, as key -> target rank.
-- Each player's highest rank is read once, however many characters they
-- have.
function PromotionPolicy.MatchSet(inputs)
    local targets = {}
    local highest = {}
    local function highestOf(player)
        if highest[player] == nil then
            highest[player] = { PromotionPolicy.HighestRank(inputs.partition, player) }
        end
        return highest[player][1]
    end
    inputs.partition:EachCharacter(function(key)
        targets[key] = matchTarget(inputs, key, highestOf)
    end)
    return targets
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

-- The characters whose time is up but who aren't fully ready, as a set of
-- keys: their rank has a time item and every one is met (see Summarize),
-- and no officer has snoozed them (see PromotionChecks:IsSnoozed) until
-- after `now`. ReadySet ignores snoozes.
function PromotionPolicy.TimeMetSet(inputs)
    local due = {}
    eachCandidate(inputs, function(key, character, itemsOf)
        local summary = PromotionPolicy.Summarize(inputs, key, itemsOf)
        if summary ~= nil and summary.timeMet and not summary.ready
            and not inputs.checks:IsSnoozed(key, inputs.now)
        then
            due[key] = true
        end
    end)
    return due
end
