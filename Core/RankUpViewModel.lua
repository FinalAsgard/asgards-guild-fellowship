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
--          due until the snooze ends, and is counted in the footer
--          instead; Ready ignores snoozes.
--   Match  the player's alts below their highest rank, on a rank set to
--          "Alts should match this rank" (PromotionPolicy.MatchSet): the row
--          lists the characters to bring up. A Ready player's row already
--          promotes them, and a snooze hides Match as it hides Due.
-- Ready rows come first, then Match, then Due, each by name.
--
-- Picking a rank (the Promote to picker, see Targets) narrows the list to
-- the players up for that rank and turns it into a grid: one column per
-- requirement of the rank, in the rank's order, and on each row one cell
-- per column. The columns come from the rank's requirement list, so a new
-- kind of requirement is just another column.
--
-- Pure: PromotionPolicy's inputs are handed in, plus how names show.
local RankUpViewModel = {
    READY = "Ready",
    DUE = "Due",
    MATCH = "Match",
    ARROW = "→ ",
    FOOTER = "Promotion happens on the guild roster, where the Ready arrow shows.",
    ANY_RANK = "Any rank",
    -- A grid cell's state.
    MET = "met",
    MISSING = "missing",
    OVERRIDDEN = "overridden",
    TICKED = "ticked",
    UNTICKED = "unticked",
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
local function found(needle, alias, names)
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

local function rankNameOf(inputs, rank)
    return (inputs.rankNames or {})[rank + 1] or ("Rank " .. rank)
end

-- The Promote to picker's choices: Any rank, then each rank that has
-- requirements, named by the rank promoted to, the newest members' first:
--   { { text = "Any rank" }, { rank = 3, text = "→ Member" }, ... }
-- where `rank` is the rank promoted to (a row's `rank`).
function RankUpViewModel.Targets(inputs)
    local targets = { { text = RankUpViewModel.ANY_RANK } }
    local ranks = inputs.requirements:Ranks()
    local index
    for index = #ranks, 1, -1 do
        local from = ranks[index]
        if from >= 1 then
            table.insert(targets, { rank = from - 1, text = RankUpViewModel.ARROW .. rankNameOf(inputs, from - 1) })
        end
    end
    return targets
end

-- A grid cell from one of PromotionPolicy.Evaluate's items: { id, kind,
-- check (an officer's checkbox), checked, state (MET, MISSING or
-- OVERRIDDEN for an automated item, TICKED or UNTICKED for a checkbox),
-- text (an automated item's detail in short: "44 d", "level 76", "not
-- seen", "≈" before an approximate date) }.
local function cellOf(item)
    local cell = { id = item.id, kind = item.kind, check = not item.automated, text = "" }
    if cell.check then
        cell.checked = item.met == true
        cell.state = cell.checked and RankUpViewModel.TICKED or RankUpViewModel.UNTICKED
        return cell
    end
    cell.text = item.short or item.detail or ""
    if item.overridden then
        cell.state = RankUpViewModel.OVERRIDDEN
    elseif item.met then
        cell.state = RankUpViewModel.MET
    else
        cell.state = RankUpViewModel.MISSING
    end
    return cell
end

-- inputs: PromotionPolicy's (partition, requirements, checks, dates, now,
-- rankNames), plus
--   normalizer  a NameNormalizer, for how names show
--   members     live roster facts by character key, for names (optional)
--   search      text to find in aliases and character names, ignoring case
--   rank        the rank promoted to that was picked (a Targets choice), or
--               nil for Any rank: just the Ready and Due players up for
--               it, as a grid
-- Returns {
--   rows    { playerId, key (the profile character), name (the alias, else
--           the main's name), status (READY, MATCH or DUE), rank, rankName
--           (the rank promoted to), rankText ("→ Member"), waiting (the
--           unmet items' labels, for Due), waitingText ("Discord name ·
--           Interview"), promote (the characters to promote, for Ready and
--           Match), promoteText ("Toolbox, Hammer") }, Ready first
--   ready, match, due, snoozed   how many of each, whatever the search
--   count   ready + match + due
--   footer  "2 Ready · 1 Match · 5 Due · 4 snoozed · Promotion happens on
--           the guild roster, ..." (Match and snoozed only when there are
--           any)
--   columns with a rank picked, the rank's requirements in order: { id,
--           label, kind, check }; each row then has `cells`, one per
--           column (see cellOf)
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
    local view = { rows = {}, ready = 0, match = 0, due = 0, snoozed = 0 }
    local picked = inputs.rank
    -- A picked rank has no Match rows: they have no checklist to show.
    local matches = picked == nil and addon.PromotionPolicy.MatchSet(inputs) or {}
    local function rankName(rank)
        return rankNameOf(inputs, rank)
    end
    if picked ~= nil then
        view.columns = {}
        local items = itemsOf(picked + 1)
        local index
        for index = 1, #items do
            table.insert(view.columns, { id = items[index].id, label = items[index].label, kind = items[index].kind,
                check = not addon.RankRequirements.IsAutomated(items[index].kind) })
        end
    end
    partition:EachPlayer(function(playerId, player)
        local key = addon.PromotionPolicy.HighestCharacter(partition, playerId)
        local status = key and addon.PromotionPolicy.Evaluate(inputs, key, itemsOf) or nil
        if picked ~= nil and (status == nil or status.nextRank ~= picked) then
            return
        end
        local snoozed = key ~= nil and inputs.checks:IsSnoozed(key, inputs.now)
        local ready = status ~= nil and status.ready
        local due = status ~= nil and not ready and status.timeMet
        if due and snoozed then
            view.snoozed = view.snoozed + 1
            due = false
        end
        local keys = inGuild(partition, playerId)
        -- Alts to bring up to the player's rank, and the highest rank any of
        -- them goes to.
        local matched, target = {}, nil
        if not ready and not snoozed then
            local index
            for index = 1, #keys do
                local alt = keys[index]
                local rank = matches[alt]
                if rank ~= nil then
                    table.insert(matched, keys[index])
                    if target == nil or rank < target then
                        target = rank
                    end
                end
            end
        end
        if not ready and not due and matched[1] == nil then
            return
        end
        if ready then
            view.ready = view.ready + 1
        elseif due then
            view.due = view.due + 1
        end
        if matched[1] ~= nil then
            view.match = view.match + 1
        end
        local characterNames = {}
        local index
        for index = 1, #keys do
            characterNames[index] = nameOf(inputs, keys[index])
        end
        local alias = player and player.alias or nil
        if type(alias) ~= "string" or alias == "" then
            alias = nil
        end
        if needle ~= "" and not found(needle, alias, characterNames) then
            return
        end
        local name = alias or (player and player.main and nameOf(inputs, player.main)) or characterNames[1]
        if matched[1] ~= nil then
            local promote = {}
            for index = 1, #matched do
                table.insert(promote, nameOf(inputs, matched[index]))
            end
            table.insert(view.rows, {
                playerId = playerId,
                key = key,
                name = name,
                status = RankUpViewModel.MATCH,
                rank = target,
                rankName = rankName(target),
                rankText = RankUpViewModel.ARROW .. rankName(target),
                promote = promote,
                promoteText = table.concat(promote, ", "),
            })
        end
        if not ready and not due then
            return
        end
        local row = {
            playerId = playerId,
            key = key,
            name = name,
            status = ready and RankUpViewModel.READY or RankUpViewModel.DUE,
            rank = status.nextRank,
            rankName = status.nextRankName,
            rankText = RankUpViewModel.ARROW .. status.nextRankName,
        }
        if picked ~= nil then
            row.cells = {}
            for index = 1, #status.items do
                row.cells[index] = cellOf(status.items[index])
            end
        end
        if ready then
            row.promote = {}
            for index = 1, #keys do
                local rank = (partition:GetCharacter(keys[index]) or {}).rank
                if type(rank) == "number" and rank > status.nextRank then
                    table.insert(row.promote, characterNames[index])
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
    local order = { [RankUpViewModel.READY] = 1, [RankUpViewModel.MATCH] = 2, [RankUpViewModel.DUE] = 3 }
    table.sort(view.rows, function(a, b)
        if a.status ~= b.status then
            return order[a.status] < order[b.status]
        end
        if lower(a.name) ~= lower(b.name) then
            return lower(a.name) < lower(b.name)
        end
        return tostring(a.playerId) < tostring(b.playerId)
    end)
    view.count = view.ready + view.match + view.due
    local parts = { view.ready .. " " .. RankUpViewModel.READY }
    if view.match > 0 then
        table.insert(parts, view.match .. " " .. RankUpViewModel.MATCH)
    end
    table.insert(parts, view.due .. " " .. RankUpViewModel.DUE)
    if view.snoozed > 0 then
        table.insert(parts, view.snoozed .. " snoozed")
    end
    table.insert(parts, RankUpViewModel.FOOTER)
    view.footer = table.concat(parts, DOT)
    return view
end
