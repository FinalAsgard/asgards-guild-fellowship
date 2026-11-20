local _, addon = ...

-- Moves saved data to a new home realm. WoW Forever hides realm names since
-- its 1.60.1 hotfix, so the add-on uses the region there instead (its
-- character and guild names are unique across a region); data saved before
-- that is keyed by the realm the game named then. Run moves it: each guild
-- partition "<guild>-<old realm>" becomes "<guild>-<realm>", and anywhere in
-- the saved data, a character key's "-<old realm>" ending ("tool
-- box-camelot", also inside "alias|tool box-camelot" or "tool
-- box-camelot:1790000000") becomes "-<realm>", in table keys and values
-- alike.
--
-- Lossless: nothing is dropped. A partition whose new key is already taken
-- stays where it was, under its old key, and so does any entry whose
-- renamed key is already taken. Running again with nothing to move changes
-- nothing.
--
-- Pure: the database and the new realm are handed in.
local RealmMigration = {}
addon.RealmMigration = RealmMigration

-- `realm` as character keys end in it: spaces removed and folded, as
-- NameNormalizer keys it.
local function keyRealm(realm)
    return addon.NameNormalizer.Fold((string.gsub(realm, "%s+", "")))
end

local function escape(text)
    return (string.gsub(text, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- The realm part of partition key `key` (after its last "-"), or nil.
local function partitionRealm(key)
    if type(key) ~= "string" then
        return nil
    end
    return string.match(key, "^.+%-([^%-]+)$")
end

-- `text` with each old realm ending a character key replaced by `realm`.
local function rewrite(text, old, realm)
    local index
    for index = 1, #old do
        local pattern = "%-" .. escape(old[index])
        text = string.gsub(text, pattern .. "$", "-" .. realm)
        text = string.gsub(text, pattern .. "([|:#])", "-" .. realm .. "%1")
    end
    return text
end

-- Rewrites every string key and value in `value`, depth first. A renamed
-- key that's already taken keeps its old name.
local function rewriteTable(value, old, realm, visited)
    if visited[value] then
        return
    end
    visited[value] = true
    local renamed = {}
    local key, inner
    for key, inner in pairs(value) do
        if type(inner) == "table" then
            rewriteTable(inner, old, realm, visited)
        elseif type(inner) == "string" then
            local text = rewrite(inner, old, realm)
            if text ~= inner then
                value[key] = text
            end
        end
        if type(key) == "string" then
            local newKey = rewrite(key, old, realm)
            if newKey ~= key then
                table.insert(renamed, { from = key, to = newKey })
            end
        end
    end
    local index
    for index = 1, #renamed do
        local move = renamed[index]
        if value[move.to] == nil then
            value[move.to] = value[move.from]
            value[move.from] = nil
        end
    end
end

-- The partitions saved under a realm other than `realm`: { { from, to } }.
local function partitionsToMove(guilds, realm)
    local moves = {}
    local key
    for key in pairs(guilds) do
        local old = partitionRealm(key)
        if old ~= nil and keyRealm(old) ~= keyRealm(realm) then
            local guildName = string.sub(key, 1, #key - #old - 1)
            table.insert(moves, {
                from = key,
                to = addon.FellowshipStore.PartitionKey({ name = guildName, realm = realm }),
                realm = old,
            })
        end
    end
    table.sort(moves, function(a, b)
        return a.from < b.from
    end)
    return moves
end

-- Moves `database`'s data to home realm `realm`. Returns how many guild
-- partitions moved and the keys of those left where they were because
-- their new key was taken: moved, kept. Nothing to move returns 0, {}.
function RealmMigration.Run(database, realm)
    if type(database) ~= "table" or type(database.guilds) ~= "table" or type(realm) ~= "string"
        or string.find(realm, "%S") == nil
    then
        return 0, {}
    end
    local moves = partitionsToMove(database.guilds, realm)
    if moves[1] == nil then
        return 0, {}
    end
    local old, seen = {}, {}
    local moved, kept = 0, {}
    local index
    for index = 1, #moves do
        local move = moves[index]
        if database.guilds[move.to] == nil then
            database.guilds[move.to] = database.guilds[move.from]
            database.guilds[move.from] = nil
            moved = moved + 1
            local folded = keyRealm(move.realm)
            if not seen[folded] then
                seen[folded] = true
                table.insert(old, folded)
            end
        else
            table.insert(kept, move.from)
        end
    end
    if old[1] ~= nil then
        -- Partitions left where they were keep their own keys too.
        local skip = {}
        for index = 1, #kept do
            skip[database.guilds[kept[index]]] = true
        end
        rewriteTable(database, old, keyRealm(realm), skip)
    end
    return moved, kept
end
