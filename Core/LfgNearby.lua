local _, addon = ...

-- The Guild LFG Board's Nearby line: guildmates online in the player's
-- zone, at any level and whatever their availability, one entry per
-- Fellowship player. Pure: the guild's facts are handed in.
local LfgNearby = {}
addon.LfgNearby = LfgNearby

-- inputs:
--   partition  the Fellowship store partition
--   members    live roster facts by key ({ online, zone, level, name })
--   display    optional function(name) -> the name as shown
-- Returns the players with a character online in `zone` (a zone name),
-- sorted by label: { id, label, characters = { { name, level, class } } }
-- with their characters online there, by name. The player of `selfKey` is
-- left out.
function LfgNearby.List(inputs, zone, selfKey)
    local partition = inputs.partition
    local members = inputs.members or {}
    local display = inputs.display or function(name)
        return name
    end
    local function nameOf(key)
        local live = members[key]
        local character = partition:GetCharacter(key)
        local name = (live and live.name) or (character and character.name) or key
        return display(name) or name
    end
    local own = selfKey and partition:GetCharacter(selfKey)
    local byPlayer, entries = {}, {}
    local key, live
    for key, live in pairs(members) do
        local character = live.online and zone ~= nil and live.zone == zone and partition:GetCharacter(key)
        if character and not (own and character.player == own.player) then
            local entry = byPlayer[character.player]
            if entry == nil then
                local player = partition:GetPlayer(character.player)
                entry = { id = character.player, label = player.alias or nameOf(player.main), characters = {} }
                byPlayer[character.player] = entry
                table.insert(entries, entry)
            end
            table.insert(entry.characters, { name = nameOf(key), level = live.level or character.level,
                class = character.class })
        end
    end
    table.sort(entries, function(a, b)
        if a.label ~= b.label then
            return a.label < b.label
        end
        return a.id < b.id
    end)
    local index
    for index = 1, #entries do
        table.sort(entries[index].characters, function(a, b)
            return a.name < b.name
        end)
    end
    return entries
end
