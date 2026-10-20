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

-- inputs: requirements, rank (the one the officer picked, or nil),
-- rankNames (the game's rank names, the guild master's first).
-- Returns { rank, rankText, nextText, mismatch, items, empty }:
--   rank      the rank shown (nil when no rank can be edited)
--   rankText  "Veteran (rank 3)"
--   nextText  "Promotes to Officer"
--   mismatch  a warning when the rank was set up under another name, or nil
--   items     { id, label, kindText, canUp, canDown } in order
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
            kindText = addon.RankRequirements.KINDS[items[index].kind],
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

-- The Promotions list's rows from PromotionPolicy.List's `evaluated`, for
-- the page's list. options:
--   expanded      set of character keys whose checklist is open
--   nameOf(key)   a character's (or officer's) name to show
--   formatDate(time)
--   anyRequirements  whether any rank has requirements
-- Rows: a heading, then per character
--   { kind = "character", key, character, ranks, progress, highest, action }
-- and, under an open one, per item
--   { kind = "item", key, item, character, ranks, ticked, needsNote, action,
--     tooltip }
-- where `tooltip` lists who ticked it, when, and the note. With no
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
                local item = row.items[itemIndex]
                local record = item.record
                local ticked = record ~= nil and record.ticked
                local tooltip
                if ticked then
                    tooltip = { "Ticked by " .. tostring(nameOf(record.by)) .. " on " .. formatDate(record.at) }
                    if record.note ~= nil then
                        table.insert(tooltip, "Note: " .. record.note)
                    end
                elseif record ~= nil then
                    tooltip = { "Unticked by " .. tostring(nameOf(record.by)) .. " on " .. formatDate(record.at) }
                end
                local needsNote = item.kind == addon.RankRequirements.KIND_CHECK_NOTE
                table.insert(rows, {
                    kind = "item",
                    key = row.key,
                    item = item.id,
                    character = "    " .. (item.met and "|cff40ff40[x]|r " or "[ ] ") .. item.label,
                    ranks = needsNote and "Needs a note" or "",
                    progress = ticked and record.note and ("\"" .. record.note .. "\"") or "",
                    highest = "",
                    ticked = ticked == true,
                    needsNote = needsNote,
                    label = item.label,
                    action = ticked and "Untick" or "Tick",
                    tooltip = tooltip,
                })
            end
        end
    end
    if evaluated[1] == nil then
        table.insert(rows, {
            kind = "empty",
            character = options.anyRequirements and PromotionsViewModel.NOBODY or PromotionsViewModel.NO_REQUIREMENTS,
        })
    end
    return rows
end
