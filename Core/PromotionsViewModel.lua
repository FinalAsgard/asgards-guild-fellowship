local _, addon = ...

-- Builds the officers' Promotions page. Pure: the caller passes the
-- requirements (RankRequirements) and the game's rank names.
local PromotionsViewModel = {
    NONE_ANYWHERE = "No rank has promotion requirements yet. Pick a rank and add the first item.",
    NONE_HERE = "This rank has no requirements.",
    NO_CUSTOM = "No custom requirements at this rank.",
    NO_RANKS = "The guild's ranks aren't known yet.",
}
addon.PromotionsViewModel = PromotionsViewModel

-- The ranks an officer can give requirements: every rank but the guild
-- master's (index 0), which has no rank above it. `rankNames` is the
-- game's list, the guild master's first.
function PromotionsViewModel.EditableRanks(rankNames)
    local ranks = {}
    local index
    for index = 2, #(rankNames or {}) do
        table.insert(ranks, index - 1)
    end
    return ranks
end

-- The rank to show: `rank` when it can be edited, else the lowest rank
-- that has requirements, else the lowest rank of all (the newest members').
function PromotionsViewModel.PickRank(rank, requirements, rankNames)
    local ranks = PromotionsViewModel.EditableRanks(rankNames)
    local index
    for index = 1, #ranks do
        if ranks[index] == rank then
            return rank
        end
    end
    local withItems = requirements:Ranks()
    for index = #withItems, 1, -1 do
        if withItems[index] >= 1 and withItems[index] <= #ranks then
            return withItems[index]
        end
    end
    return ranks[#ranks]
end

-- The rank `step` places along from `rank` (wrapping), among the editable
-- ranks.
function PromotionsViewModel.StepRank(rank, step, rankNames)
    local ranks = PromotionsViewModel.EditableRanks(rankNames)
    if ranks[1] == nil then
        return rank
    end
    local index
    for index = 1, #ranks do
        if ranks[index] == rank then
            return ranks[(index - 1 + step) % #ranks + 1]
        end
    end
    return ranks[1]
end

-- An item's kind in words, with its number: "Days at rank: 14".
function PromotionsViewModel.KindText(item)
    local text = addon.RankRequirements.KINDS[item.kind] or tostring(item.kind)
    if item.n ~= nil and addon.RankRequirements.HasNumber(item.kind) then
        text = text .. ": " .. item.n
    end
    return text
end

-- inputs: requirements, rank (the one the officer picked, or nil),
-- rankNames (the game's rank names, the guild master's first).
-- Returns { rank, rankText, nextText, mismatch, items, automated, empty }:
--   rank      the rank shown (nil when no rank can be edited)
--   rankText  "Veteran (rank 3)"
--   nextText  "Promotes to Officer"
--   mismatch  a warning when the rank was set up under another name, or nil
--   items     the custom (checkbox) items in order:
--             { id, label, needsNote, kindText, canUp, canDown }
--   automated one line per automated check, in AUTOMATED_ORDER:
--             { kind, text, enabled, id?, n?, numberText? }, `numberText`
--             what `n` is called ("Days"), nil for a check without one
--   empty     what to say instead of custom items, or nil
function PromotionsViewModel.Editor(inputs)
    local requirements, names = inputs.requirements, inputs.rankNames or {}
    local rank = PromotionsViewModel.PickRank(inputs.rank, requirements, names)
    if rank == nil then
        return { items = {}, automated = {}, empty = PromotionsViewModel.NO_RANKS }
    end
    local name = names[rank + 1]
    local model = {
        rank = rank,
        rankText = tostring(name) .. " (rank " .. rank .. ")",
        nextText = "Promotes to " .. tostring(names[rank]),
        items = {},
        automated = {},
    }
    if requirements:Mismatch(rank, name) then
        model.mismatch = "Set up when rank " .. rank .. " was called \"" .. requirements:RankName(rank) ..
            "\"; the game now calls it \"" .. tostring(name) .. "\". Check these still belong here."
    end
    local Requirements = addon.RankRequirements
    local items = requirements:Items(rank)
    local custom = {}
    local index
    for index = 1, #items do
        if not Requirements.IsAutomated(items[index].kind) then
            table.insert(custom, items[index])
        end
    end
    for index = 1, #custom do
        table.insert(model.items, {
            id = custom[index].id,
            label = custom[index].label,
            needsNote = custom[index].kind == Requirements.KIND_CHECK_NOTE,
            kindText = PromotionsViewModel.KindText(custom[index]),
            canUp = index > 1,
            canDown = index < #custom,
        })
    end
    for index = 1, #Requirements.AUTOMATED_ORDER do
        local kind = Requirements.AUTOMATED_ORDER[index]
        local held = requirements:ItemOfKind(rank, kind)
        table.insert(model.automated, {
            kind = kind,
            text = Requirements.KINDS[kind],
            enabled = held ~= nil,
            id = held and held.id or nil,
            n = held and Requirements.HasNumber(kind) and held.n or nil,
            numberText = Requirements.AUTOMATED[kind].number,
        })
    end
    if items[1] == nil then
        model.empty = requirements:Ranks()[1] == nil and PromotionsViewModel.NONE_ANYWHERE
            or PromotionsViewModel.NONE_HERE
    elseif custom[1] == nil then
        model.empty = PromotionsViewModel.NO_CUSTOM
    end
    return model
end

-- One checklist item's status, actions and tooltip for character `key`
-- (see PanelRows).
function PromotionsViewModel.ItemRow(key, item, nameOf, formatDate)
    local record = item.record
    local ticked = record ~= nil and record.ticked
    local verb = item.automated and "Overridden" or "Ticked"
    local tooltip
    if ticked then
        tooltip = { verb .. " by " .. tostring(nameOf(record.by)) .. " on " .. formatDate(record.at) }
        if record.note ~= nil then
            table.insert(tooltip, (item.automated and "Reason: " or "Note: ") .. record.note)
        end
    elseif record ~= nil then
        tooltip = { (item.automated and "Override removed by " or "Unticked by ") .. tostring(nameOf(record.by))
            .. " on " .. formatDate(record.at) }
    end
    local row = {
        kind = "item",
        key = key,
        item = item.id,
        ticked = ticked == true,
        label = item.label,
        tooltip = tooltip,
    }
    if item.automated then
        row.ranks = item.detail or ""
        row.progress = item.overridden and "overridden" or ""
        if ticked then
            row.action = "Undo override"
        elseif not item.met then
            row.action = "Override"
        end
        return row
    end
    row.needsNote = item.kind == addon.RankRequirements.KIND_CHECK_NOTE
    row.ranks = row.needsNote and "Needs a note" or ""
    row.progress = ticked and record.note and ("\"" .. record.note .. "\"") or ""
    return row
end

-- The player panel's Promotion tab, from the same evaluation as the
-- roster's Ready markers (so the two always agree). Each character is one
-- line, marked Ready when it meets every requirement, that opens (when in
-- `options.expanded`) to show its checklist. `characters` lists the
-- player's characters in the guild:
--   { key, name, rankName, evaluated (PromotionPolicy.Evaluate, or nil
--     when its rank has no requirements), lastPromotion (a MembershipDates
--     record, or nil) }
-- Add-ons can't promote: an officer promotes in the game's guild window.
-- options: officer (true for an officer's view: check boxes, Override,
-- who ticked, notes and reasons; false for a member's own view,
-- read-only, with just each item's status and detail), highestRankName,
-- nameOf(key), formatDate(time), expanded (a set of the character keys
-- whose checklists are open).
-- Rows: { kind = "stat", text } lines, then for each character
--   { kind = "promotion", text, key, toggle?, expanded? }, `toggle` when
--   it has a checklist (or a promotion date) to open, and when open
--   { kind = "promotion", text, key, item, action?, ticked, needsNote,
--     tooltip?, check, checked, canCheck?, note? }
-- where `action` names an automated item's button, Override or Undo
-- override (officers only). An item row is drawn with a check box,
-- `checked` when met; `canCheck` for an officer's custom item (ticking the
-- box ticks it). An officer's needs-a-note item (with `note`, its saved
-- note while ticked) is followed by the line its note is typed on, and
-- shown on once saved; a failed automated item's by one for the
-- override's optional reason:
--   { kind = "promotion", key, item, noteInput = true, ticked, note?,
--     reason? }
function PromotionsViewModel.PanelRows(characters, options)
    options = options or {}
    local nameOf = options.nameOf or tostring
    local formatDate = options.formatDate or tostring
    local expanded = options.expanded or {}
    local rows = {}
    if options.officer and options.highestRankName ~= nil then
        table.insert(rows, { kind = "stat", text = "Highest rank: " .. options.highestRankName })
    end
    local index
    for index = 1, #characters do
        local character = characters[index]
        local evaluated = character.evaluated
        local text = tostring(character.name) .. ": " .. tostring(character.rankName)
        if evaluated == nil then
            text = text .. "  |cff9d9d9dno requirements|r"
        else
            text = text .. " -> " .. evaluated.nextRankName .. ", " .. evaluated.met .. " of " .. evaluated.total ..
                (evaluated.ready and "  |cff40ff40Ready for promotion|r" or "")
        end
        local last = options.officer and character.lastPromotion or nil
        local header = { kind = "promotion", key = character.key, text = text }
        table.insert(rows, header)
        if evaluated ~= nil or last ~= nil then
            header.toggle = true
            header.expanded = expanded[character.key] == true
            header.text = (header.expanded and "[-] " or "[+] ") .. text
        end
        if not header.expanded then
            evaluated, last = nil, nil
        end
        if last ~= nil then
            table.insert(rows, { kind = "promotion", key = character.key, text = "    |cff9d9d9dPromoted on " ..
                formatDate(last.time) .. (last.promoter and (" by " .. tostring(nameOf(last.promoter))) or "") .. "|r" })
        end
        local itemIndex
        for itemIndex = 1, #(evaluated and evaluated.items or {}) do
            local evaluatedItem = evaluated.items[itemIndex]
            local item = PromotionsViewModel.ItemRow(character.key, evaluatedItem, nameOf, formatDate)
            local detail = item.ranks ~= "" and item.ranks or nil
            local row = {
                kind = "promotion",
                key = character.key,
                item = item.item,
                ticked = item.ticked,
                check = true,
                checked = evaluatedItem.met == true,
                text = item.label .. (detail and ("  |cff9d9d9d" .. detail .. "|r") or ""),
            }
            if options.officer then
                -- A custom item's note is on its own line, below.
                if item.progress ~= "" and evaluatedItem.automated then
                    row.text = row.text .. "  |cff9d9d9d" .. item.progress .. "|r"
                end
                row.needsNote = item.needsNote
                row.tooltip = item.tooltip
                if evaluatedItem.automated then
                    -- An automated item's box shows whether it's met;
                    -- Override and Undo override are its button.
                    row.action = item.action
                else
                    row.canCheck = true
                end
            end
            table.insert(rows, row)
            local record = evaluatedItem.record
            if row.canCheck and row.needsNote then
                row.note = row.ticked and record ~= nil and record.note or nil
                table.insert(rows, { kind = "promotion", key = character.key, item = item.item, noteInput = true,
                    ticked = row.ticked, note = row.note })
            elseif options.officer and evaluatedItem.automated and not evaluatedItem.met then
                -- A failed check: an override's reason, typed first.
                table.insert(rows, { kind = "promotion", key = character.key, item = item.item, noteInput = true,
                    reason = true, ticked = false })
            end
        end
    end
    if characters[1] == nil then
        table.insert(rows, { kind = "empty", text = "No characters in the guild" })
    end
    return rows
end
