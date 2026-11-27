local _, addon = ...

-- The Guild LFG Board's Find guildmates list: guildmates online now who
-- could fill a slot in the player's listed party, by LfgRelevance's rules
-- (their level in the listing's range and, for a dungeon, a role they play
-- open). The player's own characters and everyone in the party (by player)
-- are left out. Guildmates in a listed group on the board are marked and
-- go last. Pure: the guild's facts are handed in.
local LfgFillCandidates = {}
addon.LfgFillCandidates = LfgFillCandidates

-- inputs:
--   partition  the Fellowship store partition
--   members    live roster facts by key ({ online, level, name })
--   rolesOf    function(key) -> the roles that character plays, or nil
--   listing    the party's listing as the board holds one ({ kind,
--              minLevel?, maxLevel?, openRoles?, size, maxSize })
--   selfKey    the logged-in character's key
--   partyKeys  the keys of the characters in the player's party
--   grouped    set of the keys in listed groups on the board ({ [key] =
--              true })
--   display    optional function(name) -> the name as shown
-- Returns rows { key, name, whisper (the saved full name), level, class,
-- label (the player's alias or main), inGroup }: not in a group first,
-- then by name.
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
    local rows = {}
    local key, live
    for key, live in pairs(members) do
        local character = live.online and partition:GetCharacter(key)
        if character and not excluded[character.player] then
            local level = live.level or character.level
            local roles = inputs.rolesOf and inputs.rolesOf(key) or {}
            if addon.LfgRelevance.Fits(inputs.listing, { level = level, roles = roles }) then
                local player = partition:GetPlayer(character.player)
                table.insert(rows, {
                    key = key,
                    name = nameOf(key),
                    whisper = character.name or key,
                    level = level,
                    class = character.class,
                    label = player and (player.alias or nameOf(player.main)) or nil,
                    inGroup = grouped[key] == true,
                })
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.inGroup ~= b.inGroup then
            return not a.inGroup
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.key < b.key
    end)
    return rows
end
