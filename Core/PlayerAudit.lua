local _, addon = ...

-- A player's change log and sync data, in words: the player panel's
-- Changes section and `/agf probe player`. Pure: works on a
-- FellowshipStore partition and never touches the game.
local PlayerAudit = {
    -- How many logged changes the probe prints.
    PROBE_CHANGES = 10,
}
addon.PlayerAudit = PlayerAudit

local FIELDS = { alias = "Alias", discord = "Discord", location = "Location", bio = "Bio" }

local function quoted(text)
    if type(text) ~= "string" or text == "" then
        return "none"
    end
    return '"' .. text .. '"'
end

-- One logged change (see FellowshipStore's LogChange) as text, without its
-- date. `name(key)` -> how a character is shown.
function PlayerAudit.ChangeText(entry, name)
    local what
    if entry.kind == "bio" then
        what = (entry.to == nil or entry.to == "") and "Bio cleared" or "Bio changed"
    elseif FIELDS[entry.kind] ~= nil then
        what = FIELDS[entry.kind] .. " changed from " .. quoted(entry.from) .. " to " .. quoted(entry.to)
    elseif entry.kind == "main" then
        what = "Main changed from " .. name(entry.from) .. " to " .. name(entry.to)
    elseif entry.kind == "joined" then
        what = name(entry.character) .. " joined"
        if entry.from ~= nil and entry.from ~= entry.character then
            what = what .. " from " .. name(entry.from) .. "'s player"
        end
    elseif entry.kind == "left" then
        what = name(entry.character) .. " left for " .. name(entry.to) .. "'s player"
    elseif entry.kind == "link" then
        what = name(entry.character) .. "'s main set to " .. name(entry.to)
        if entry.from ~= nil and entry.from ~= entry.to then
            what = what .. " (was " .. name(entry.from) .. ")"
        end
    else
        what = tostring(entry.kind)
    end
    if entry.by ~= nil then
        what = what .. ", by " .. name(entry.by)
    end
    if entry.via == "sync" then
        what = what .. " (guild sync)"
    elseif entry.via == "local" then
        what = what .. " (here)"
    end
    return what
end

-- The ids of the players `text` names, in id order: a character's name (or
-- key, through `keyOf(name)` -> key), or an alias.
function PlayerAudit.FindPlayers(partition, text, keyOf)
    local ids = {}
    if type(text) ~= "string" or text == "" then
        return ids
    end
    local key = keyOf(text)
    local character = key and partition:GetCharacter(key) or partition:GetCharacter(text)
    if character ~= nil then
        return { character.player }
    end
    local seen = {}
    local aliased = partition:PlayersWithAlias(text)
    local index
    for index = 1, #aliased do
        seen[aliased[index]] = true
        table.insert(ids, aliased[index])
    end
    -- A character's name without its realm.
    local folded = string.lower(text)
    partition:EachCharacter(function(_, record)
        local name = type(record.name) == "string" and string.lower(string.match(record.name, "^[^-]+")) or nil
        if name == folded and not seen[record.player] then
            seen[record.player] = true
            table.insert(ids, record.player)
        end
    end)
    table.sort(ids)
    return ids
end

-- What `/agf probe player` prints about player `playerId`: its alias and
-- that alias's stamp, each character's link and Discord username with
-- theirs, and the newest logged changes. `options.name(key)` -> how a
-- character is shown, `options.formatTime(timestamp)` -> text.
function PlayerAudit.ProbeLines(partition, playerId, options)
    local name, formatTime = options.name, options.formatTime
    local player = partition:GetPlayer(playerId)
    if player == nil then
        return { "No such player." }
    end
    local function stamp(at, by)
        if at == nil or at == 0 then
            return "not stamped"
        end
        return "stamped " .. formatTime(at) .. " by " .. (by and name(by) or "?")
    end
    local lines = { "Player " .. name(player.main) .. ", alias " .. quoted(player.alias) .. ":" }
    if player.aliasAt ~= nil then
        local line = "  Alias " .. stamp(player.aliasAt, player.aliasBy)
        if player.aliasFor ~= nil then
            line = line .. ", set through " .. name(player.aliasFor)
        end
        if not partition:AliasAnchored(playerId) then
            line = line .. "; doesn't count here: " .. name(player.aliasFor) .. " isn't one of this player's characters"
        end
        table.insert(lines, line)
    else
        table.insert(lines, "  Alias not stamped (from a note, or set before guild sync)" ..
            (player.aliasSource and (", from " .. player.aliasSource) or ""))
    end
    local keys = partition:CharactersOf(playerId)
    local index
    for index = 1, #keys do
        local character = partition:GetCharacter(keys[index])
        local line = "  " .. name(keys[index]) .. (keys[index] == player.main and " (main)" or "") ..
            ": link from " .. tostring(character.source or "?") .. ", " .. stamp(character.mainAt, character.mainBy)
        if character.discord ~= nil then
            line = line .. "; Discord " .. quoted(character.discord) .. " " ..
                stamp(character.discordAt, character.discordBy)
        end
        table.insert(lines, line)
    end
    table.insert(lines, "  Discord shown: " .. quoted((partition:PlayerProfileText(playerId, "discord"))))
    local changes = partition:GetChanges(playerId)
    if changes[1] == nil then
        table.insert(lines, "  No changes logged yet.")
        return lines
    end
    local last = math.max(1, #changes - PlayerAudit.PROBE_CHANGES + 1)
    table.insert(lines, "  " .. #changes .. " changes logged; the last " .. (#changes - last + 1) ..
        ", newest first:")
    for index = #changes, last, -1 do
        local entry = changes[index]
        if type(entry) == "table" then
            table.insert(lines, "    " .. (entry.at and formatTime(entry.at) or "?") .. ": " ..
                PlayerAudit.ChangeText(entry, name))
        end
    end
    return lines
end
