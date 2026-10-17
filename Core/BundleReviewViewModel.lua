local _, addon = ...

-- Builds the officers' review of one member's bundle of suggestions (a
-- ConflictViewModel "bundle" row): the submitting player as it is now
-- (Before) and as it would be with every suggestion approved (Suggested),
-- in plain words, and one line per suggestion to approve or deny. Pure:
-- the caller passes the partition and a NameNormalizer.
local BundleReviewViewModel = {
    -- Following mains that point at other characters stops after this many
    -- steps, so a loop in the suggestions can't hang the review.
    MAX_STEPS = 10,
}
addon.BundleReviewViewModel = BundleReviewViewModel

local function nameOf(inputs, key)
    local character = inputs.partition:GetCharacter(key)
    return inputs.normalizer:Display(character and character.name or key) or key
end

local function currentMain(partition, key)
    local character = partition:GetCharacter(key)
    local player = character and partition:GetPlayer(character.player)
    return player and player.main or key
end

-- "Main: Hammer" (with "(declared)" when it is), "Alts: Toolbox, Wrench"
-- (or "none"), "Alias: Tools" (or "none").
local function picture(inputs, main, alts, alias, declared)
    local names = {}
    local index
    for index = 1, #alts do
        names[index] = nameOf(inputs, alts[index])
    end
    table.sort(names)
    return {
        "Main: " .. nameOf(inputs, main) .. (declared and " (declared)" or ""),
        "Alts: " .. (names[1] and table.concat(names, ", ") or "none"),
        "Alias: " .. ((alias ~= nil and alias ~= "") and alias or "none"),
    }
end

-- inputs: partition, normalizer, bundle (a ConflictViewModel bundle row).
-- Returns:
--   { group, title, before, suggested, items }
-- `before` and `suggested` are lists of lines describing the submitting
-- player; `items` has one entry per suggestion:
--   { character, kind, text }
-- where `text` reads "Bolt: Alt of Toolbox → Alt of Hammer".
function BundleReviewViewModel.Build(inputs)
    local partition = inputs.partition
    local bundle = inputs.bundle
    local items = bundle.items or {}
    local from = items[1] and items[1].from
    local own = from and partition:GetCharacter(from)
    local player = own and partition:GetPlayer(own.player)

    -- Everyone the bundle touches: the player's characters, the characters
    -- the suggestions are about, and the mains they name.
    local involved, mains = {}, {}
    local function involve(key)
        if key ~= nil and partition:GetCharacter(key) ~= nil and mains[key] == nil then
            mains[key] = currentMain(partition, key)
            table.insert(involved, key)
        end
    end
    local keys = own and partition:CharactersOf(own.player) or {}
    local index
    for index = 1, #keys do
        involve(keys[index])
    end
    local alias = player and player.alias or nil
    local suggestedAlias = alias
    -- Declared mains as suggested; any other is as it is now.
    local suggestedDeclared = {}
    local function isDeclared(key)
        if suggestedDeclared[key] ~= nil then
            return suggestedDeclared[key]
        end
        return partition:IsDeclared(key)
    end
    local lines = {}
    for index = 1, #items do
        local item = items[index]
        involve(item.character)
        if item.kind == addon.SuggestionService.KIND_DECLARED then
            suggestedDeclared[item.character] = item.suggestion and item.suggestion.declared == true
            table.insert(lines, {
                character = item.character,
                kind = item.kind,
                text = item.name .. ": " .. item.current .. " → " .. item.suggests,
            })
        elseif item.kind == addon.SuggestionService.KIND_DISCORD then
            -- Often about a guildmate, not the member's own player.
            table.insert(lines, {
                character = item.character,
                kind = item.kind,
                text = item.name .. "'s Discord: " .. item.current .. " → " .. item.suggests,
            })
        elseif item.kind == addon.SuggestionService.KIND_ALIAS then
            suggestedAlias = item.suggestion and item.suggestion.alias or suggestedAlias
            table.insert(lines, {
                character = item.character,
                kind = item.kind,
                text = "Alias: " .. item.current .. " → " .. item.suggests,
            })
        else
            local main = item.suggestion and item.suggestion.main
            involve(main)
            table.insert(lines, {
                character = item.character,
                kind = item.kind,
                text = item.name .. ": " .. item.current .. " → " .. item.suggests,
            })
        end
    end

    local before = { "Not in the roster any more" }
    if player ~= nil then
        local alts = {}
        for index = 1, #keys do
            if keys[index] ~= player.main then
                table.insert(alts, keys[index])
            end
        end
        before = picture(inputs, player.main, alts, alias, partition:IsDeclared(player.main))
    end

    -- With every suggestion approved: each character follows its suggested
    -- main, as far as the mains lead.
    local suggestedMains = {}
    for index = 1, #involved do
        suggestedMains[involved[index]] = mains[involved[index]]
    end
    for index = 1, #items do
        local item = items[index]
        if item.kind == addon.SuggestionService.KIND_MAIN and item.suggestion and item.suggestion.main then
            suggestedMains[item.character] = item.suggestion.main
        end
    end
    local function resolve(key)
        local steps = 0
        while suggestedMains[key] ~= nil and suggestedMains[key] ~= key and steps < BundleReviewViewModel.MAX_STEPS do
            key = suggestedMains[key]
            steps = steps + 1
        end
        return key
    end
    local suggested = before
    if own ~= nil then
        local main = resolve(from)
        local alts = {}
        for index = 1, #involved do
            local key = involved[index]
            if key ~= main and resolve(key) == main and partition:IsInGuild(key) then
                table.insert(alts, key)
            end
        end
        suggested = picture(inputs, main, alts, suggestedAlias, isDeclared(main))
    end

    return {
        group = bundle.group,
        title = "Review: " .. tostring(bundle.name),
        before = before,
        suggested = suggested,
        items = lines,
    }
end
