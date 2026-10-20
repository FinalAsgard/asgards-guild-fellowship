local _, addon = ...

-- Builds the officers' review of one member's bundle of suggestions (a
-- ConflictViewModel "bundle" row): who suggested it, one before/after block
-- for every player the bundle changes, the live guild note of each
-- character involved, and one line per suggestion to approve or deny.
-- Pure: the caller passes the partition, live roster facts, and a
-- NameNormalizer.
local BundleReviewViewModel = {
    -- Following mains that point at other characters stops after this many
    -- steps, so a loop in the suggestions can't hang the review.
    MAX_STEPS = 10,
    -- How a block's line compares with the other side of the block.
    SAME = "same",
    ADDED = "added",
    REMOVED = "removed",
}
addon.BundleReviewViewModel = BundleReviewViewModel

local function nameOf(inputs, key)
    local live = inputs.members[key]
    local character = inputs.partition:GetCharacter(key)
    local raw = (live and live.name) or (character and character.name) or key
    return inputs.normalizer:Display(raw) or key
end

local function currentMain(partition, key)
    local character = partition:GetCharacter(key)
    local player = character and partition:GetPlayer(character.player)
    return player and player.main or key
end

local function text(value)
    return (value ~= nil and value ~= "") and value or "none"
end

-- One side of a block, one line each: "Main: Hammer" (with "(declared)"
-- when it is), "Alias: Tools", "Discord: hammer#1" (or "none"), then
-- "Alt: Bolt" for each alt, sorted, or "Alts: none".
local function picture(inputs, side)
    local lines = {
        "Main: " .. nameOf(inputs, side.main) .. (side.declared and " (declared)" or ""),
        "Alias: " .. text(side.alias),
        "Discord: " .. text(side.discord),
    }
    local names = {}
    local index
    for index = 1, #side.alts do
        names[index] = nameOf(inputs, side.alts[index])
    end
    table.sort(names)
    if names[1] == nil then
        table.insert(lines, "Alts: none")
    end
    for index = 1, #names do
        table.insert(lines, "Alt: " .. names[index])
    end
    return lines
end

-- Marks each line of `lines` `mark` when the other side lacks it, else
-- SAME. True as the second result when any line was marked.
local function marked(lines, other, mark)
    local present = {}
    local index
    for index = 1, #other do
        present[other[index]] = true
    end
    local result, changed = {}, false
    for index = 1, #lines do
        local line = { text = lines[index], mark = BundleReviewViewModel.SAME }
        if not present[lines[index]] then
            line.mark = mark
            changed = true
        end
        result[index] = line
    end
    return result, changed
end

-- inputs: partition, normalizer, bundle (a ConflictViewModel bundle row),
-- and members (live roster facts by key, for the guild notes).
-- Returns:
--   { group, title, suggestedBy, players, notes, items }
-- `suggestedBy` reads "Suggested by Bolt (Hammer)". `players` has one block
-- per player the bundle changes, the submitting player's first:
--   { name, before = { line... }, after = { line... } }
-- where each line is { text, mark }: SAME, or REMOVED on the before side
-- and ADDED on the after side for what the bundle changes. A character
-- that would become a player of its own gets a block with an empty before
-- side. `notes` lists { name, note } for each character the suggestions
-- name, with its live guild note (nil when it isn't in the roster).
-- `items` has one entry per suggestion:
--   { character, kind, text }
-- where `text` reads "Bolt: Alt of Toolbox → Alt of Hammer".
function BundleReviewViewModel.Build(inputs)
    inputs.members = inputs.members or {}
    local partition = inputs.partition
    local bundle = inputs.bundle
    local items = bundle.items or {}
    local from = items[1] and items[1].from

    -- Everyone the bundle touches: the submitting member, the characters
    -- the suggestions are about, and the mains they name, each with every
    -- character of their player now.
    local named, namedSeen = {}, {}
    local function name(key)
        if key ~= nil and not namedSeen[key] then
            namedSeen[key] = true
            table.insert(named, key)
        end
    end
    name(from)
    local index
    for index = 1, #items do
        name(items[index].character)
        name(items[index].suggestion and items[index].suggestion.main)
    end
    local universe, inUniverse = {}, {}
    local function include(key)
        if key ~= nil and partition:GetCharacter(key) ~= nil and not inUniverse[key] then
            inUniverse[key] = true
            table.insert(universe, key)
        end
    end
    for index = 1, #named do
        local character = partition:GetCharacter(named[index])
        if character ~= nil then
            local keys = partition:CharactersOf(character.player)
            local keyIndex
            for keyIndex = 1, #keys do
                include(keys[keyIndex])
            end
            include(named[index])
        end
    end

    -- What the suggestions change: mains by character; alias, Discord, and
    -- declared main by the player they're about now.
    local suggestedMains = {}
    for index = 1, #universe do
        suggestedMains[universe[index]] = currentMain(partition, universe[index])
    end
    local aliases, discords, declared = {}, {}, {}
    local lines = {}
    for index = 1, #items do
        local item = items[index]
        local character = partition:GetCharacter(item.character)
        local playerId = character and character.player
        local suggestion = item.suggestion or {}
        local line = item.name .. ": " .. item.current .. " → " .. item.suggests
        if item.kind == addon.SuggestionService.KIND_DECLARED then
            declared[item.character] = suggestion.declared == true
        elseif item.kind == addon.SuggestionService.KIND_DISCORD then
            -- Often about a guildmate, not the member's own player.
            if playerId ~= nil then
                discords[playerId] = suggestion.text or ""
            end
            line = item.name .. "'s Discord: " .. item.current .. " → " .. item.suggests
        elseif item.kind == addon.SuggestionService.KIND_ALIAS then
            if playerId ~= nil then
                aliases[playerId] = suggestion.alias or ""
            end
            line = "Alias: " .. item.current .. " → " .. item.suggests
        elseif item.kind == addon.SuggestionService.KIND_MAIN and suggestion.main ~= nil
            and inUniverse[item.character]
        then
            suggestedMains[item.character] = suggestion.main
        end
        table.insert(lines, { character = item.character, kind = item.kind, text = line })
    end

    -- With every suggestion approved: each character follows its suggested
    -- main, as far as the mains lead.
    local function resolve(key)
        local steps = 0
        while suggestedMains[key] ~= nil and suggestedMains[key] ~= key and steps < BundleReviewViewModel.MAX_STEPS do
            key = suggestedMains[key]
            steps = steps + 1
        end
        return key
    end
    local function isDeclared(key)
        if declared[key] ~= nil then
            return declared[key]
        end
        return partition:IsDeclared(key)
    end
    local function altsOf(main, follow)
        local alts = {}
        for index = 1, #universe do
            local key = universe[index]
            if key ~= main and follow(key) == main and partition:IsInGuild(key) then
                table.insert(alts, key)
            end
        end
        return alts
    end
    local function profileText(playerId, field)
        return playerId ~= nil and partition:PlayerProfileText(playerId, field) or nil
    end
    local function suggested(values, playerId, field)
        if playerId ~= nil and values[playerId] ~= nil then
            return values[playerId]
        end
        if field == "alias" then
            local player = playerId ~= nil and partition:GetPlayer(playerId)
            return player and player.alias or nil
        end
        return profileText(playerId, field)
    end

    -- One block per player now, the submitting player's first, then one for
    -- each character that would become a player of its own. Only blocks
    -- with a change are shown.
    local players = {}
    local beforeMains, seenMain = {}, {}
    for index = 1, #universe do
        local main = currentMain(partition, universe[index])
        if not seenMain[main] then
            seenMain[main] = true
            table.insert(beforeMains, main)
        end
    end
    -- Where each player's main leads with the suggestions approved: that
    -- character heads a player that already exists.
    local claimed = {}
    for index = 1, #beforeMains do
        claimed[resolve(beforeMains[index])] = true
    end
    local function addBlock(label, beforeLines, afterLines)
        local before, removed = marked(beforeLines, afterLines, BundleReviewViewModel.REMOVED)
        local after, added = marked(afterLines, beforeLines, BundleReviewViewModel.ADDED)
        if removed or added then
            table.insert(players, { name = label, before = before, after = after })
        end
    end
    local function currentOf(key)
        return currentMain(partition, key)
    end
    for index = 1, #beforeMains do
        local main = beforeMains[index]
        local character = partition:GetCharacter(main)
        local playerId = character and character.player
        local player = playerId ~= nil and partition:GetPlayer(playerId) or nil
        local nextMain = resolve(main)
        -- Joining another player takes on that player's alias and Discord.
        local nextCharacter = partition:GetCharacter(nextMain)
        local nextPlayerId = nextCharacter and nextCharacter.player or playerId
        local beforeLines = picture(inputs, {
            main = main,
            alts = altsOf(main, currentOf),
            declared = partition:IsDeclared(main),
            alias = player and player.alias or nil,
            discord = profileText(playerId, "discord"),
        })
        local afterLines = picture(inputs, {
            main = nextMain,
            alts = altsOf(nextMain, resolve),
            declared = isDeclared(nextMain),
            alias = suggested(aliases, nextPlayerId, "alias"),
            discord = suggested(discords, nextPlayerId, "discord"),
        })
        local label = (player and player.alias) or nameOf(inputs, main)
        addBlock(label, beforeLines, afterLines)
    end
    -- Characters leaving their player to be a main of their own.
    local newMains, seenNew = {}, {}
    for index = 1, #universe do
        local main = resolve(universe[index])
        if not claimed[main] and not seenNew[main] and partition:IsInGuild(main) then
            seenNew[main] = true
            table.insert(newMains, main)
        end
    end
    for index = 1, #newMains do
        local main = newMains[index]
        addBlock(nameOf(inputs, main), {}, picture(inputs, {
            main = main,
            alts = altsOf(main, resolve),
            declared = isDeclared(main),
        }))
    end

    local notes = {}
    for index = 1, #named do
        local key = named[index]
        if partition:GetCharacter(key) ~= nil then
            local live = inputs.members[key]
            table.insert(notes, { name = nameOf(inputs, key), note = live and live.note or nil })
        end
    end

    return {
        group = bundle.group,
        title = "Review: " .. tostring(bundle.name),
        suggestedBy = "Suggested by " .. tostring(bundle.suggestedBy),
        players = players,
        notes = notes,
        items = lines,
    }
end
