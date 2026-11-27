local _, addon = ...

-- The officers' Rank management page: who is up for a rank. Each player is
-- judged once, on their highest-ranked character (PromotionPolicy's
-- profile), and named by the rank they'd be promoted to ("→ Member"),
-- never "current → next".
--
-- The Due list holds the players whose time-based requirements are met:
--   Ready  every requirement is met; the row lists the characters to
--          promote (every one of the player's characters in the guild below
--          the rank promoted to)
--   Due    the time is up but something else isn't; the row says what it's
--          waiting on ("Discord name · Interview"). A snoozed player isn't
--          due until the snooze ends; Ready ignores snoozes.
-- Ready rows come first, then Due, each by name.
--
-- Pure: PromotionPolicy's inputs are handed in, plus how names show.
local RankUpViewModel = {
    READY = "Ready",
    DUE = "Due",
    ARROW = "→ ",
    FOOTER = "Promotion happens on the guild roster, where the Ready arrow shows.",
}
addon.RankUpViewModel = RankUpViewModel

local DOT = " · "

local function lower(text)
    return string.lower(text or "")
end

-- How character `key` shows.
local function nameOf(inputs, key)
    local live = (inputs.members or {})[key]
    local raw = (live and live.name) or (inputs.partition:GetCharacter(key) or {}).name or key
    return inputs.normalizer and inputs.normalizer:Display(raw) or raw
end

-- The player's characters in the guild, main first.
local function inGuild(partition, playerId)
    local keys = {}
    local all = partition:CharactersOf(playerId)
    local index
    for index = 1, #all do
        if partition:IsInGuild(all[index]) then
            table.insert(keys, all[index])
        end
    end
    return keys
end

-- Whether `needle` (lowercase, not empty) is in the alias or any of the
-- names.
local function matches(needle, alias, names)
    if string.find(lower(alias), needle, 1, true) ~= nil then
        return true
    end
    local index
    for index = 1, #names do
        if string.find(lower(names[index]), needle, 1, true) ~= nil then
            return true
        end
    end
    return false
end

-- inputs: PromotionPolicy's (partition, requirements, checks, dates, now,
-- rankNames), plus
--   normalizer  a NameNormalizer, for how names show
--   members     live roster facts by character key, for names (optional)
--   search      text to find in aliases and character names, ignoring case
-- Returns {
--   rows    { playerId, key (the profile character), name (the alias, else
--           the main's name), status (READY or DUE), rank, rankName (the
--           rank promoted to), rankText ("→ Member"), waiting (the unmet
--           items' labels, for Due), waitingText ("Discord name ·
--           Interview"), promote (the characters to promote, for Ready),
--           promoteText ("Toolbox, Hammer") }, Ready first
--   ready, due   how many of each, whatever the search
--   count   ready + due
--   footer  "2 Ready · 5 Due · Promotion happens on the guild roster, ..."
-- }
function RankUpViewModel.Due(inputs)
    local partition = inputs.partition
    local needle = string.match(lower(inputs.search), "^%s*(.-)%s*$")
    local itemsByRank = {}
    local function itemsOf(rank)
        if itemsByRank[rank] == nil then
            itemsByRank[rank] = inputs.requirements:Items(rank)
        end
        return itemsByRank[rank]
    end
    local view = { rows = {}, ready = 0, due = 0 }
    partition:EachPlayer(function(playerId, player)
        local key = addon.PromotionPolicy.HighestCharacter(partition, playerId)
        local status = key and addon.PromotionPolicy.Evaluate(inputs, key, itemsOf) or nil
        if status == nil then
            return
        end
        local ready = status.ready
        if not ready and not (status.timeMet and not inputs.checks:IsSnoozed(key, inputs.now)) then
            return
        end
        if ready then
            view.ready = view.ready + 1
        else
            view.due = view.due + 1
        end
        local keys = inGuild(partition, playerId)
        local names = {}
        local index
        for index = 1, #keys do
            names[index] = nameOf(inputs, keys[index])
        end
        local alias = player and player.alias or nil
        if type(alias) ~= "string" or alias == "" then
            alias = nil
        end
        if needle ~= "" and not matches(needle, alias, names) then
            return
        end
        local row = {
            playerId = playerId,
            key = key,
            name = alias or (player and player.main and nameOf(inputs, player.main)) or names[1],
            status = ready and RankUpViewModel.READY or RankUpViewModel.DUE,
            rank = status.nextRank,
            rankName = status.nextRankName,
            rankText = RankUpViewModel.ARROW .. status.nextRankName,
        }
        if ready then
            row.promote = {}
            for index = 1, #keys do
                local rank = (partition:GetCharacter(keys[index]) or {}).rank
                if type(rank) == "number" and rank > status.nextRank then
                    table.insert(row.promote, names[index])
                end
            end
            row.promoteText = table.concat(row.promote, ", ")
        else
            row.waiting = {}
            for index = 1, #status.items do
                if not status.items[index].met then
                    table.insert(row.waiting, status.items[index].label)
                end
            end
            row.waitingText = table.concat(row.waiting, DOT)
        end
        table.insert(view.rows, row)
    end)
    table.sort(view.rows, function(a, b)
        if a.status ~= b.status then
            return a.status == RankUpViewModel.READY
        end
        if lower(a.name) ~= lower(b.name) then
            return lower(a.name) < lower(b.name)
        end
        return tostring(a.playerId) < tostring(b.playerId)
    end)
    view.count = view.ready + view.due
    view.footer = view.ready .. " " .. RankUpViewModel.READY .. DOT .. view.due .. " " .. RankUpViewModel.DUE
        .. DOT .. RankUpViewModel.FOOTER
    return view
end
