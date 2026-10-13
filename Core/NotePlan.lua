local _, addon = ...

-- Which guild notes an official change touches, and the markers each one
-- should carry now. Pure: the caller passes the partition (already changed),
-- the characters the change involved, and a NameNormalizer.
--
-- An alt's note gets `>Main`. The main's note gets `@Alias` when the player
-- has one (an alias of several words can't be read back from a note, so it
-- gets none). A character on its own, as a split-off one is, gets no main
-- marker, which removes its old one.
local NotePlan = {}
addon.NotePlan = NotePlan

-- An alias a note can carry: one word, as NoteParser reads it.
local function noteAlias(alias)
    if type(alias) ~= "string" then
        return nil
    end
    local word = string.match(alias, addon.NoteParser.ALIAS_WORD)
    return word == alias and alias or nil
end

-- partition, keys (a set of character keys), normalizer.
-- Returns a list, sorted by key, of { key, name, markers = { main, alias } }
-- for each of those characters still in the guild.
function NotePlan.Build(partition, keys, normalizer)
    local sorted = {}
    local key
    for key in pairs(keys or {}) do
        if partition:IsInGuild(key) then
            table.insert(sorted, key)
        end
    end
    table.sort(sorted)
    local plan = {}
    local index
    for index = 1, #sorted do
        key = sorted[index]
        local character = partition:GetCharacter(key)
        local player = partition:GetPlayer(character.player)
        if player ~= nil then
            local markers = {}
            if player.main ~= key then
                local main = partition:GetCharacter(player.main)
                markers.main = normalizer:Display(main and main.name or player.main)
            else
                markers.alias = noteAlias(player.alias)
            end
            table.insert(plan, {
                key = key,
                name = normalizer:Display(character.name) or key,
                markers = markers,
            })
        end
    end
    return plan
end
