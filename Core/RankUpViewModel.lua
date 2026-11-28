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
-- The Missing filter (see MissingChoices) narrows the list to the Due
-- players missing one requirement, and the footer counts them out of
-- everyone up for that rank.
--
-- The All players list (see All) has every player, each with its status in
-- words: Ready, Due, Match, Snoozed until <date>, Not yet: N days, or No
-- requirements, the soonest first.
--
-- Pure: PromotionPolicy's inputs are handed in, plus how names show.
local RankUpViewModel = {
    READY = "Ready",
    DUE = "Due",
    MATCH = "Match",
    ARROW = "→ ",
    FOOTER = "Promotion happens on the guild roster, where the Ready arrow shows.",
    ANY_RANK = "Any rank",
    OVERRIDE_TEXT = "met by override",
    -- A grid cell's state.
    MET = "met",
    MISSING = "missing",
    OVERRIDDEN = "overridden",
    TICKED = "ticked",
    UNTICKED = "unticked",
    -- All players' statuses, besides READY, DUE and MATCH.
    SNOOZED = "Snoozed",
    NOT_YET = "Not yet",
    NONE = "No requirements",
    -- All players' status filter.
    FILTER_ALL = "all",
    FILTER_SNOOZED = "snoozed",
    FILTER_NOT_YET = "notyet",
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

-- The Missing filter's choices: the picked rank's requirements, in the
-- rank's order, or for Any rank every rank's, the newest members' first:
--   { { rank = 3, id, label, text = "Has a Discord name set" }, ... }
-- where `rank` is the rank promoted to, and `text` names it too for Any
-- rank ("Has a Discord name set (→ Member)").
function RankUpViewModel.MissingChoices(inputs)
    local choices = {}
    local function add(from, named)
        local items = inputs.requirements:Items(from)
        local index
        for index = 1, #items do
            local label = items[index].label
            table.insert(choices, { rank = from - 1, id = items[index].id, label = label,
                text = named and (label .. " (" .. RankUpViewModel.ARROW .. rankNameOf(inputs, from - 1) .. ")")
                    or label })
        end
    end
    if inputs.rank ~= nil then
        add(inputs.rank + 1, false)
        return choices
    end
    local ranks = inputs.requirements:Ranks()
    local index
    for index = #ranks, 1, -1 do
        if ranks[index] >= 1 then
            add(ranks[index], true)
        end
    end
    return choices
end

-- Whether Evaluate's `status` has item `id` unmet.
local function lacks(status, id)
    local index
    for index = 1, #status.items do
        if status.items[index].id == id then
            return not status.items[index].met
        end
    end
    return false
end

-- A grid cell from one of PromotionPolicy.Evaluate's items: { id, kind,
-- check (an officer's checkbox), checked, needsNote (a checkbox ticked
-- with a note), state (MET, MISSING or OVERRIDDEN for an automated item,
-- TICKED or UNTICKED for a checkbox), text, by (who ticked or overrode
-- it, by name), note (its note, or an override's reason) }. `text` is an
-- automated item's detail in short ("44 d", "level 76", "not seen", "≈"
-- before an approximate date), "met by override" when overridden; and for
-- a ticked checkbox its note in quotes, else who ticked it.
local function cellOf(inputs, item)
    local cell = { id = item.id, kind = item.kind, check = not item.automated, text = "" }
    local record = item.record
    if record ~= nil and record.ticked then
        cell.by = record.by and nameOf(inputs, record.by) or nil
        cell.note = record.note
    end
    if cell.check then
        cell.checked = item.met == true
        cell.needsNote = item.kind == addon.RankRequirements.KIND_CHECK_NOTE
        cell.state = cell.checked and RankUpViewModel.TICKED or RankUpViewModel.UNTICKED
        if cell.checked and cell.note ~= nil then
            cell.text = "\"" .. cell.note .. "\""
        elseif cell.checked and cell.by ~= nil then
            cell.text = "by " .. cell.by
        end
        return cell
    end
    cell.text = item.short or item.detail or ""
    if item.overridden then
        cell.state = RankUpViewModel.OVERRIDDEN
        cell.text = RankUpViewModel.OVERRIDE_TEXT
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
--   missing     a MissingChoices choice, or nil: just the Due players up
--               for its rank who are missing it
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
--   missing with the Missing filter, { count (the Due players missing it),
--           of (everyone Ready or Due up for its rank) }, whatever the
--           search; the footer then says "9 of 22 players due → Member are
--           missing: Has a Discord name set · Promotion happens ..."
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
    local missing = inputs.missing
    -- A picked rank has no Match rows: they have no checklist to show; nor
    -- does the Missing filter, as Match has no requirement to miss.
    local matches = (picked == nil and missing == nil) and addon.PromotionPolicy.MatchSet(inputs) or {}
    if missing ~= nil then
        view.missing = { count = 0, of = 0 }
    end
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
        local keys = inGuild(partition, playerId)
        -- Alts to bring up to the player's rank, and the highest rank any of
        -- them goes to.
        local matched, target = {}, nil
        if not ready then
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
        -- A snooze hides a player's Due or Match work (never Ready), and
        -- they're counted once, as All players shows them Snoozed. The
        -- count follows a picked rank but not the Missing filter.
        if snoozed and not ready and (due or matched[1] ~= nil) then
            view.snoozed = view.snoozed + 1
            due, matched, target = false, {}, nil
        end
        if not ready and not due and matched[1] == nil then
            return
        end
        if missing ~= nil then
            if status.nextRank ~= missing.rank then
                return
            end
            view.missing.of = view.missing.of + 1
            if not due or not lacks(status, missing.id) then
                return
            end
            view.missing.count = view.missing.count + 1
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
                row.cells[index] = cellOf(inputs, status.items[index])
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
    if missing ~= nil then
        local count, of = view.missing.count, view.missing.of
        view.footer = count .. " of " .. of .. (of == 1 and " player" or " players") .. " due "
            .. RankUpViewModel.ARROW .. rankName(missing.rank) .. (count == 1 and " is" or " are") .. " missing: "
            .. missing.label .. DOT .. RankUpViewModel.FOOTER
        return view
    end
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

local function plural(count, word)
    return count .. " " .. word .. (count == 1 and "" or "s")
end

-- Player `playerId`'s standing, as All rows it (see there), or nil when
-- none of the player's characters is in the guild; plus Evaluate's status
-- for the profile character (nil without a checklist), and the player's
-- characters in the guild, main first. `matches` is MatchSet's, and
-- `itemsOf(rank)` a rank's items.
local function standing(inputs, playerId, matches, itemsOf)
    local partition = inputs.partition
    local key = addon.PromotionPolicy.HighestCharacter(partition, playerId)
    if key == nil then
        return nil
    end
    local status = addon.PromotionPolicy.Evaluate(inputs, key, itemsOf)
    local keys = inGuild(partition, playerId)
    local target
    local index
    for index = 1, #keys do
        local rank = matches[keys[index]]
        if rank ~= nil and (target == nil or rank < target) then
            target = rank
        end
    end
    local snooze = inputs.checks:IsSnoozed(key, inputs.now) and inputs.checks:SnoozeOf(key) or nil
    local row = { playerId = playerId, key = key, target = target }
    if status ~= nil and status.ready then
        row.status, row.statusText = RankUpViewModel.READY, RankUpViewModel.READY
    elseif snooze ~= nil then
        row.status = RankUpViewModel.SNOOZED
        row.untilTime = snooze.untilTime
        row.snoozedBy = snooze.by and nameOf(inputs, snooze.by) or nil
        local ends
        if inputs.dateText ~= nil then
            ends = " until " .. inputs.dateText(snooze.untilTime)
        else
            ends = " for " .. plural(math.ceil((snooze.untilTime - inputs.now) / addon.PromotionPolicy.DAY),
                "more day")
        end
        row.statusText = RankUpViewModel.SNOOZED .. ends .. (row.snoozedBy and (" by " .. row.snoozedBy) or "")
    elseif status ~= nil and status.timeMet then
        row.status, row.statusText = RankUpViewModel.DUE, RankUpViewModel.DUE
    elseif target ~= nil then
        row.status, row.statusText = RankUpViewModel.MATCH, RankUpViewModel.MATCH
    elseif status ~= nil then
        row.status = RankUpViewModel.NOT_YET
        row.days = status.remaining
        row.statusText = RankUpViewModel.NOT_YET .. (row.days and (": " .. plural(row.days, "day")) or "")
    else
        row.status, row.statusText = RankUpViewModel.NONE, RankUpViewModel.NONE
    end
    if row.status == RankUpViewModel.MATCH or status == nil then
        row.rank = target
    else
        row.rank = status.nextRank
    end
    if row.rank ~= nil then
        row.rankText = RankUpViewModel.ARROW .. rankNameOf(inputs, row.rank)
    end
    return row, status, keys
end

-- A rank's items, read once each, as itemsOf(rank).
local function itemsReader(inputs)
    local itemsByRank = {}
    return function(rank)
        if itemsByRank[rank] == nil then
            itemsByRank[rank] = inputs.requirements:Items(rank)
        end
        return itemsByRank[rank]
    end
end

-- inputs: as for Due (search, but no rank), plus
--   filter    FILTER_ALL (or nil), FILTER_SNOOZED or FILTER_NOT_YET
--   dateText  function(time) -> how a date shows ("Dec 4"); without it, a
--             snooze says how long it has left ("for 3 more days")
-- Returns {
--   rows    every player in the guild (narrowed by search and filter): {
--           playerId, key (the profile character), name, status (READY,
--           DUE, MATCH, SNOOZED, NOT_YET or NONE), rank, rankText ("→
--           Member", nil for NONE), statusText ("Snoozed until Dec 4 by
--           Toolbox", "Not yet: 5 days"), days (Not yet's days to go),
--           untilTime and snoozedBy (a snooze's end, and who snoozed, by
--           name) }, soonest first: Ready, Match, Due, then Snoozed by its
--           end, Not yet by its days (unknown last), then No requirements,
--           each by name
--   count   every player, whatever the search and filter
--   snoozed, notYet   how many of each, likewise
-- }
-- A Ready player is Ready even while snoozed, as on Due; a player with
-- alts behind but nothing due is Match.
function RankUpViewModel.All(inputs)
    local partition = inputs.partition
    local needle = string.match(lower(inputs.search), "^%s*(.-)%s*$")
    local filter = inputs.filter or RankUpViewModel.FILTER_ALL
    local itemsOf = itemsReader(inputs)
    local matches = addon.PromotionPolicy.MatchSet(inputs)
    local view = { rows = {}, count = 0, snoozed = 0, notYet = 0 }
    partition:EachPlayer(function(playerId, player)
        local row, _, keys = standing(inputs, playerId, matches, itemsOf)
        if row == nil then
            return
        end
        view.count = view.count + 1
        if row.status == RankUpViewModel.SNOOZED then
            view.snoozed = view.snoozed + 1
        elseif row.status == RankUpViewModel.NOT_YET then
            view.notYet = view.notYet + 1
        end
        local index
        if (filter == RankUpViewModel.FILTER_SNOOZED and row.status ~= RankUpViewModel.SNOOZED)
            or (filter == RankUpViewModel.FILTER_NOT_YET and row.status ~= RankUpViewModel.NOT_YET)
        then
            return
        end
        local characterNames = {}
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
        row.name = alias or (player and player.main and nameOf(inputs, player.main)) or characterNames[1]
        table.insert(view.rows, row)
    end)
    local order = {
        [RankUpViewModel.READY] = 1,
        [RankUpViewModel.MATCH] = 2,
        [RankUpViewModel.DUE] = 3,
        [RankUpViewModel.SNOOZED] = 4,
        [RankUpViewModel.NOT_YET] = 5,
        [RankUpViewModel.NONE] = 6,
    }
    local function soon(row)
        if row.status == RankUpViewModel.SNOOZED then
            return row.untilTime
        end
        return row.days or math.huge
    end
    table.sort(view.rows, function(a, b)
        if a.status ~= b.status then
            return order[a.status] < order[b.status]
        end
        if soon(a) ~= soon(b) then
            return soon(a) < soon(b)
        end
        if lower(a.name) ~= lower(b.name) then
            return lower(a.name) < lower(b.name)
        end
        return tostring(a.playerId) < tostring(b.playerId)
    end)
    return view
end

-- Player `playerId`'s checklist, for the player panel's Rank management
-- tab, or nil when none of the player's characters is in the guild:
--   { playerId, key (the profile character), status, statusText, rank,
--     rankText, untilTime, snoozedBy (as All's rows), promote (the
--     characters to promote: for Ready, each below the rank promoted to;
--     for Match, the alts behind), promoteText, items }
-- where each item is a grid cell (see cellOf) plus its `label` and
-- `detail` in words: an automated item's ("5 of 7 days", "met by
-- override", with an override's reason after it), a check's note or who
-- ticked it. A player with no requirements has no items.
function RankUpViewModel.Checklist(inputs, playerId)
    local partition = inputs.partition
    local itemsOf = itemsReader(inputs)
    -- Match targets for this player's characters only, not the guild's.
    local matches = {}
    local _, alt
    for _, alt in ipairs(inGuild(partition, playerId)) do
        matches[alt] = addon.PromotionPolicy.MatchTarget(inputs, alt)
    end
    local row, status, keys = standing(inputs, playerId, matches, itemsOf)
    if row == nil then
        return nil
    end
    row.items = {}
    row.promote = {}
    local index
    if row.status == RankUpViewModel.MATCH then
        for index = 1, #keys do
            if matches[keys[index]] ~= nil then
                table.insert(row.promote, nameOf(inputs, keys[index]))
            end
        end
    elseif row.status == RankUpViewModel.READY then
        for index = 1, #keys do
            local rank = (partition:GetCharacter(keys[index]) or {}).rank
            if type(rank) == "number" and rank > status.nextRank then
                table.insert(row.promote, nameOf(inputs, keys[index]))
            end
        end
    end
    row.promoteText = table.concat(row.promote, ", ")
    if status ~= nil then
        for index = 1, #status.items do
            local item = status.items[index]
            local cell = cellOf(inputs, item)
            cell.label = item.label
            if cell.check then
                cell.detail = cell.text
            elseif item.overridden then
                cell.detail = RankUpViewModel.OVERRIDE_TEXT .. (cell.note and (DOT .. cell.note) or "")
            else
                cell.detail = item.detail or cell.text
            end
            row.items[index] = cell
        end
    end
    return row
end
