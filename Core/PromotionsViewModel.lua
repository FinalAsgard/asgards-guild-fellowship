local _, addon = ...

-- Builds the officers' Promotions page. Pure: the caller passes the
-- requirements (RankRequirements) and the game's rank names.
local PromotionsViewModel = {
    NONE_ANYWHERE = "No rank has promotion requirements yet. Pick a rank and add the first item.",
    NONE_HERE = "This rank has no requirements.",
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
    if item.n ~= nil then
        text = text .. ": " .. item.n
    end
    return text
end

-- inputs: requirements, rank (the one the officer picked, or nil),
-- rankNames (the game's rank names, the guild master's first).
-- Returns { rank, rankText, nextText, mismatch, items, empty }:
--   rank      the rank shown (nil when no rank can be edited)
--   rankText  "Veteran (rank 3)"
--   nextText  "Promotes to Officer"
--   mismatch  a warning when the rank was set up under another name, or nil
--   items     { id, label, kindText, n, canUp, canDown } in order
--   empty     what to say instead of items, or nil
function PromotionsViewModel.Editor(inputs)
    local requirements, names = inputs.requirements, inputs.rankNames or {}
    local rank = PromotionsViewModel.PickRank(inputs.rank, requirements, names)
    if rank == nil then
        return { items = {}, empty = PromotionsViewModel.NO_RANKS }
    end
    local name = names[rank + 1]
    local model = {
        rank = rank,
        rankText = tostring(name) .. " (rank " .. rank .. ")",
        nextText = "Promotes to " .. tostring(names[rank]),
        items = {},
    }
    if requirements:Mismatch(rank, name) then
        model.mismatch = "Set up when rank " .. rank .. " was called \"" .. requirements:RankName(rank) ..
            "\"; the game now calls it \"" .. tostring(name) .. "\". Check these still belong here."
    end
    local items = requirements:Items(rank)
    local index
    for index = 1, #items do
        table.insert(model.items, {
            id = items[index].id,
            label = items[index].label,
            kindText = PromotionsViewModel.KindText(items[index]),
            n = items[index].n,
            canUp = index > 1,
            canDown = index < #items,
        })
    end
    if items[1] == nil then
        model.empty = requirements:Ranks()[1] == nil and PromotionsViewModel.NONE_ANYWHERE
            or PromotionsViewModel.NONE_HERE
    end
    return model
end

PromotionsViewModel.NOBODY = "Nobody is at a rank with requirements."
PromotionsViewModel.NO_REQUIREMENTS = "No rank has promotion requirements yet. Use Edit requirements to add some."

-- One checklist item's row under character `key` (see List).
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
        character = "    " .. (item.met and "|cff40ff40[x]|r " or "[ ] ") .. item.label,
        highest = "",
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
            row.askReason = true
        end
        return row
    end
    row.needsNote = item.kind == addon.RankRequirements.KIND_CHECK_NOTE
    row.ranks = row.needsNote and "Needs a note" or ""
    row.progress = ticked and record.note and ("\"" .. record.note .. "\"") or ""
    row.action = ticked and "Untick" or "Tick"
    return row
end

-- The row under an open checklist that promotes `row` (an evaluated
-- character): `action` is "Promote" or "Mark as promoted", `unmet` the
-- labels of the items not met (asked about first), and `confirm` the
-- question to ask then.
function PromotionsViewModel.PromoteRow(row, action)
    local unmet = {}
    local index
    for index = 1, #row.items do
        if not row.items[index].met then
            table.insert(unmet, row.items[index].label)
        end
    end
    local promote = {
        kind = "promote",
        key = row.key,
        character = "    Promote to " .. tostring(row.nextRankName),
        ranks = "",
        progress = "",
        highest = "",
        action = action,
        unmet = unmet,
        name = row.name,
    }
    if unmet[1] ~= nil then
        promote.confirm = "Promote " .. tostring(row.name) .. "? Not met: " .. table.concat(unmet, ", ")
        promote.tooltip = { "Not met:" }
        for index = 1, #unmet do
            table.insert(promote.tooltip, unmet[index])
        end
    end
    return promote
end

-- The Promotions list's rows from PromotionPolicy.List's `evaluated`, for
-- the page's list. An automated item's row shows its detail; a failed one
-- offers Override (`askReason`: the officer may give a reason), and an
-- overridden one Undo override. options:
--   expanded      set of character keys whose checklist is open
--   nameOf(key)   a character's (or officer's) name to show
--   formatDate(time)
--   anyRequirements  whether any rank has requirements
--   promoteAction(key) -> "Promote", "Mark as promoted", or nil when this
--                 officer can't promote that character
--   filtered      true when characters have checklists but the filters or
--                 search hide them all
-- Rows: a heading, then per character
--   { kind = "character", key, character, ranks, progress, highest, action }
-- and, under an open one, per item
--   { kind = "item", key, item, character, ranks, ticked, needsNote,
--     askReason, action, tooltip }
-- then its PromoteRow when promoteAction names one. `tooltip` lists who
-- ticked (or overrode) it, when, and the note (or reason). With no
-- characters, one { kind = "empty" } row says why.
function PromotionsViewModel.List(evaluated, options)
    options = options or {}
    local expanded = options.expanded or {}
    local nameOf = options.nameOf or tostring
    local formatDate = options.formatDate or tostring
    local rows = {
        { kind = "heading", character = "Character", ranks = "Rank", progress = "Progress", highest = "Player's highest" },
    }
    local index
    for index = 1, #evaluated do
        local row = evaluated[index]
        local open = expanded[row.key] == true
        table.insert(rows, {
            kind = "character",
            key = row.key,
            character = (row.ready and "|cff40ff40Ready|r " or "") .. tostring(row.name),
            ranks = row.rankName .. " -> " .. row.nextRankName,
            progress = row.met .. " of " .. row.total,
            highest = row.highestRankName or "",
            action = open and "Close" or "Open",
        })
        if open then
            local itemIndex
            for itemIndex = 1, #row.items do
                table.insert(rows, PromotionsViewModel.ItemRow(row.key, row.items[itemIndex], nameOf, formatDate))
            end
            local promote = options.promoteAction and options.promoteAction(row.key)
            if promote ~= nil then
                table.insert(rows, PromotionsViewModel.PromoteRow(row, promote))
            end
        end
    end
    if evaluated[1] == nil then
        local text = PromotionsViewModel.NO_REQUIREMENTS
        if options.filtered then
            text = PromotionsViewModel.NO_MATCH
        elseif options.anyRequirements then
            text = PromotionsViewModel.NOBODY
        end
        table.insert(rows, { kind = "empty", character = text })
    end
    return rows
end

-- The player panel's Promotion section, from the same evaluation as the
-- Promotions tab (so the two always agree). `characters` lists the
-- player's characters in the guild:
--   { key, name, rankName, evaluated (PromotionPolicy.Evaluate, or nil
--     when its rank has no requirements), lastPromotion (a MembershipDates
--     record, or nil), promoteAction ("Promote", "Mark as promoted", nil) }
-- options: officer (true for an officer's view: tick, override and promote
-- buttons, who ticked, notes and reasons; false for a member's own view,
-- read-only, with just each item's status and detail), highestRankName,
-- nameOf(key), formatDate(time).
-- Rows: { kind = "section" }, then { kind = "stat", text } lines, and
--   { kind = "promotion", text, key, item?, action?, ticked, needsNote,
--     askReason, promote?, confirm?, tooltip? }
-- where `action` names the row's button (officers only).
function PromotionsViewModel.PanelRows(characters, options)
    options = options or {}
    local nameOf = options.nameOf or tostring
    local formatDate = options.formatDate or tostring
    local rows = { { kind = "section", text = "Promotion" } }
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
                (evaluated.ready and "  |cff40ff40Ready|r" or "")
        end
        table.insert(rows, { kind = "promotion", key = character.key, text = text })
        local last = character.lastPromotion
        if options.officer and last ~= nil then
            table.insert(rows, { kind = "promotion", key = character.key, text = "    |cff9d9d9dPromoted on " ..
                formatDate(last.time) .. (last.promoter and (" by " .. tostring(nameOf(last.promoter))) or "") .. "|r" })
        end
        local itemIndex
        for itemIndex = 1, #(evaluated and evaluated.items or {}) do
            local item = PromotionsViewModel.ItemRow(character.key, evaluated.items[itemIndex], nameOf, formatDate)
            local detail = item.ranks ~= "" and item.ranks or nil
            local row = {
                kind = "promotion",
                key = character.key,
                item = item.item,
                ticked = item.ticked,
                text = item.character .. (detail and ("  |cff9d9d9d" .. detail .. "|r") or ""),
            }
            if options.officer then
                if item.progress ~= "" then
                    row.text = row.text .. "  |cff9d9d9d" .. item.progress .. "|r"
                end
                row.action = item.action
                row.needsNote = item.needsNote
                row.askReason = item.askReason
                row.tooltip = item.tooltip
            end
            table.insert(rows, row)
        end
        if options.officer and evaluated ~= nil and character.promoteAction ~= nil then
            evaluated.name = evaluated.name or character.name
            local promote = PromotionsViewModel.PromoteRow(evaluated, character.promoteAction)
            table.insert(rows, {
                kind = "promotion",
                key = character.key,
                promote = true,
                text = promote.character,
                action = promote.confirm and (character.promoteAction .. "...") or character.promoteAction,
                confirm = promote.confirm,
                tooltip = promote.tooltip,
            })
        end
    end
    if characters[1] == nil then
        table.insert(rows, { kind = "empty", text = "No characters in the guild" })
    end
    return rows
end

PromotionsViewModel.NO_MATCH ="Nobody matches. Tick In progress to see everyone working toward a rank."

-- The tab's name with how many characters are ready: "Promotions (4)".
function PromotionsViewModel.TabLabel(ready)
    if type(ready) == "number" and ready > 0 then
        return "Promotions (" .. ready .. ")"
    end
    return "Promotions"
end

-- Where the list's controls stand, from PromotionPolicy.Query's result and
-- the filters: { pageText, page, pages, ready, progress, ranks, tabLabel,
-- badge (the ready count, or "") },
-- `ranks` being { rank, name, shown } for each rank with requirements.
function PromotionsViewModel.Controls(result, filters, rankNames)
    filters = filters or {}
    local hidden = filters.hiddenRanks or {}
    local names = rankNames or {}
    local controls = {
        page = result.page,
        pages = result.pages,
        pageText = "Page " .. result.page .. " of " .. result.pages .. " (" .. result.total ..
            (result.total == 1 and " character)" or " characters)"),
        ready = filters.ready == true,
        progress = filters.progress == true,
        ranks = {},
        tabLabel = PromotionsViewModel.TabLabel(result.ready),
        badge = (result.ready or 0) > 0 and tostring(result.ready) or "",
    }
    local index
    for index = 1, #(result.ranks or {}) do
        local rank = result.ranks[index]
        table.insert(controls.ranks, { rank = rank, name = names[rank + 1] or ("Rank " .. rank),
            shown = not hidden[rank] })
    end
    return controls
end
