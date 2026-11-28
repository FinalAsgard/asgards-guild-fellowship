local _, addon = ...

-- Builds Rank management's Requirements tab (the requirements editor).
-- Pure: the caller passes the requirements (RankRequirements) and the
-- game's rank names.
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

-- Rank management's Requirements tab: each rank that can have requirements,
-- named by the rank promoted to, the newest members' first:
--   { { rank (the rank the requirements are on), text ("→ Member"), count
--       (how many requirements), countText ("3 requirements") } }
function PromotionsViewModel.RankList(requirements, rankNames)
    local names = rankNames or {}
    local ranks = PromotionsViewModel.EditableRanks(names)
    local list = {}
    local index
    for index = #ranks, 1, -1 do
        local rank = ranks[index]
        local count = #requirements:Items(rank)
        table.insert(list, {
            rank = rank,
            text = "→ " .. tostring(names[rank] or ("Rank " .. (rank - 1))),
            count = count,
            countText = count == 0 and "None" or (count .. (count == 1 and " requirement" or " requirements")),
        })
    end
    return list
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
--   matchAlts whether the rank's "Alts should match this rank" box is
--             ticked (nil for the guild master's rank, which has none)
--   snoozeDays how many days Not ready snoozes for at the rank (nil for
--             the guild master's rank, likewise)
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
    if rank >= 1 then
        model.matchAlts = requirements:MatchesAlts(rank)
        model.snoozeDays = requirements:SnoozeDays(rank)
    end
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
