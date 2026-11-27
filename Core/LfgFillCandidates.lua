local _, addon = ...

-- The Guild LFG Board's Find guildmates list: guildmates online now who
-- could fill a slot in the player's listed party, by LfgRelevance's rules
-- (their level in the listing's range and, for a dungeon, a role they play
-- open), then offline characters that fit whose player is online on
-- another, to ask to log over. The player's own characters and everyone in
-- the party (by player) are left out, and so are players with nothing
-- online. Guildmates in a listed group on the board are marked and go last.
-- Pure: the guild's facts are handed in.
local LfgFillCandidates = {
    ONLINE = "online",
    ALT = "alt",
}
addon.LfgFillCandidates = LfgFillCandidates

-- inputs:
--   partition  the Fellowship store partition
--   members    live roster facts by key ({ online, level, name })
--   rolesOf    function(key) -> the roles that character plays, or nil
--   listing    the party's listing as the board holds one ({ kind,
--              minLevel?, maxLevel?, openRoles?, size, maxSize }), with
--              `label` (how its purpose reads) for the log-over whisper
--   selfKey    the logged-in character's key
--   partyKeys  the keys of the characters in the player's party
--   grouped    set of the keys in listed groups on the board ({ [key] =
--              true })
--   display    optional function(name) -> the name as shown
--   className  optional function(classToken) -> the class as the game
--              names it
-- Returns rows { key, kind, name, whisper (the saved full name to whisper),
-- level, class, className?, label (the player's alias or main), inGroup }.
-- An alt row (kind ALT) also has onlineKey and onlineName (the player's
-- character online now, whom `whisper` is to) and `message` (the log-over
-- request). Not in a group first; online before alts; then by name.
function LfgFillCandidates.List(inputs)
    local partition = inputs.partition
    local members = inputs.members or {}
    local grouped = inputs.grouped or {}
    local display = inputs.display or function(name)
        return name
    end
    local function nameOf(key)
        local live = members[key]
        local character = partition:GetCharacter(key)
        local name = (live and live.name) or (character and character.name) or key
        return display(name) or name
    end
    -- The players left out: the player's own, and the party's.
    local excluded = {}
    local function exclude(key)
        local character = key and partition:GetCharacter(key)
        if character ~= nil then
            excluded[character.player] = true
        end
    end
    exclude(inputs.selfKey)
    local index
    for index = 1, #(inputs.partyKeys or {}) do
        exclude(inputs.partyKeys[index])
    end
    -- Each player's character online now (the first by name, when more
    -- than one is).
    local onlineOf = {}
    local key, live
    for key, live in pairs(members) do
        local character = live.online and partition:GetCharacter(key)
        if character and not excluded[character.player] then
            local current = onlineOf[character.player]
            if current == nil or nameOf(key) < nameOf(current) then
                onlineOf[character.player] = key
            end
        end
    end
    local rows = {}
    local function fits(key, level)
        local roles = inputs.rolesOf and inputs.rolesOf(key) or {}
        return addon.LfgRelevance.Fits(inputs.listing, { level = level, roles = roles })
    end
    local function row(key, character, level, kind)
        local player = partition:GetPlayer(character.player)
        return {
            key = key,
            kind = kind,
            name = nameOf(key),
            whisper = character.name or key,
            level = level,
            class = character.class,
            className = inputs.className and inputs.className(character.class) or nil,
            label = player and (player.alias or nameOf(player.main)) or nil,
            inGroup = grouped[key] == true,
        }
    end
    local playerId, onlineKey
    for playerId, onlineKey in pairs(onlineOf) do
        local keys = partition:CharactersOf(playerId)
        local index
        for index = 1, #keys do
            local key = keys[index]
            local character = partition:GetCharacter(key)
            local live = members[key]
            if character ~= nil and live ~= nil then
                local level = live.level or character.level
                if fits(key, level) then
                    if live.online then
                        table.insert(rows, row(key, character, level, LfgFillCandidates.ONLINE))
                    else
                        -- An alt: whispered on the character online now, which
                        -- marks it in a group.
                        local entry = row(key, character, level, LfgFillCandidates.ALT)
                        local online = partition:GetCharacter(onlineKey)
                        entry.onlineKey = onlineKey
                        entry.onlineName = nameOf(onlineKey)
                        entry.whisper = online and online.name or onlineKey
                        entry.inGroup = grouped[onlineKey] == true
                        entry.message = LfgFillCandidates.LogOver(inputs.listing.label, entry.name)
                        table.insert(rows, entry)
                    end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.inGroup ~= b.inGroup then
            return not a.inGroup
        end
        if a.kind ~= b.kind then
            return a.kind == LfgFillCandidates.ONLINE
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.key < b.key
    end)
    return rows
end

-- The whisper asking a guildmate to log over to their alt `altName` for a
-- listing whose purpose reads `label`.
function LfgFillCandidates.LogOver(label, altName)
    return "Could you log over to " .. tostring(altName) .. "? We have a spot for them" ..
        (label and (" in " .. label) or "") .. "."
end
