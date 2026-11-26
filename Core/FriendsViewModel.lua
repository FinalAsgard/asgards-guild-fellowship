local _, addon = ...

-- The Friends page's left column and its picker. The left column holds the
-- Friend slots (FellowshipStore.FRIEND_SLOTS of them): the pinned players
-- as cards, online first, then by name, and an empty card for each open
-- slot after them. Each pinned key is read as its player on every build, so
-- merges, re-links and alias changes follow along, and two keys of one
-- player show one card. A Friend with no character left in the guild keeps
-- their card, as "Left the guild". Under them, Most grouped with holds the
-- players grouped with most who aren't Friends (GroupFriends' Top 5), in
-- that order, each with their party count.
--
-- The picker (Choose a friend) lists every player with a character in the
-- guild, except the user and the pinned Friends, sorted by how often the
-- user grouped with them, then by name.
--
-- Pure: the partition, live roster facts and lookups are handed in.
local FriendsViewModel = {
    LEFT_GUILD = "Left the guild",
    ONLINE = "Online",
    NEVER_GROUPED = "Never grouped",
}
addon.FriendsViewModel = FriendsViewModel

-- An optional input's answer (up to two values), or nil when it's missing
-- or fails.
local function ask(callback, ...)
    if callback == nil then
        return nil
    end
    local ok, first, second = pcall(callback, ...)
    if not ok then
        return nil
    end
    return first, second
end

local function lower(text)
    return string.lower(text or "")
end

-- The player character `key` belongs to, or nil when it isn't stored.
local function playerOf(partition, key)
    local character = partition:GetCharacter(key)
    return character and character.player or nil
end

-- What a card shows for player `playerId` (or for `key` alone, a character
-- no longer stored): { playerId, key, name, mainName, level, classToken,
-- className, color, online, left, status }.
local function describe(inputs, playerId, key)
    local partition = inputs.partition
    local members = inputs.members or {}
    local normalizer = inputs.normalizer
    local function display(raw)
        return normalizer and normalizer:Display(raw) or raw
    end
    local player = playerId and partition:GetPlayer(playerId) or nil
    local keys = player and partition:CharactersOf(playerId) or { key }
    local mainKey = player and player.main or key
    local main = partition:GetCharacter(mainKey) or {}
    local live = members[mainKey] or {}
    local online, left = false, true
    local index
    for index = 1, #keys do
        if partition:GetCharacter(keys[index]) ~= nil and partition:IsInGuild(keys[index]) then
            left = false
            if (members[keys[index]] or {}).online then
                online = true
            end
        end
    end
    local mainName = display(live.name or main.name) or mainKey
    local classToken = live.classToken or main.class
    local alias = player and player.alias or nil
    if type(alias) ~= "string" or alias == "" then
        alias = nil
    end
    local status = ""
    if left then
        status = FriendsViewModel.LEFT_GUILD
    elseif online then
        status = FriendsViewModel.ONLINE
    end
    return {
        playerId = playerId or key,
        key = key,
        keys = keys,
        -- The large name: the alias, else the main's name.
        name = alias or mainName,
        alias = alias,
        mainName = mainName,
        level = live.level or main.level,
        classToken = classToken,
        className = ask(inputs.className, classToken),
        -- The class color ("ffrrggbb"), as the roster colors it.
        color = ask(inputs.classColor, classToken),
        online = online and not left,
        left = left,
        status = status,
    }
end

-- Online first, then by name, then by player id so the order never changes.
local function byOnlineThenName(a, b)
    if a.online ~= b.online then
        return a.online
    end
    if lower(a.name) ~= lower(b.name) then
        return lower(a.name) < lower(b.name)
    end
    return tostring(a.playerId) < tostring(b.playerId)
end

-- The pinned Friends, one per player, in slot order: { card }.
local function pinned(inputs)
    local cards, seen = {}, {}
    local keys = inputs.friendKeys or {}
    local index
    for index = 1, #keys do
        local key = keys[index]
        local playerId = playerOf(inputs.partition, key)
        local owner = playerId or key
        if not seen[owner] then
            seen[owner] = true
            table.insert(cards, describe(inputs, playerId, key))
        end
    end
    return cards
end

-- inputs:
--   partition    the guild partition
--   friendKeys   the pinned character keys (FellowshipStore:GetFriends)
--   members      live roster facts by character key
--   normalizer   a NameNormalizer, for how names show
--   classColor   function(classToken) -> "ffrrggbb" or nil
--   className    function(classToken) -> the class as the game names it
--   mostGrouped  GroupFriends:MostGrouped(): { { player, count } } in order
--   selected     the player id the page has selected, or nil
-- Returns { friends = { card }, empty (open slots), full, mostGrouped =
-- { card with count and countText ("12×") }, selected (the selected player
-- id when it has a card, else nil), default (the player to select when the
-- page opens: the first Friend, else the first Most grouped, else nil) }.
function FriendsViewModel.Build(inputs)
    local partition = inputs.partition
    local friends = pinned(inputs)
    table.sort(friends, byOnlineThenName)
    local mostGrouped = {}
    local entries = inputs.mostGrouped or {}
    local index
    for index = 1, #entries do
        local player = entries[index].player
        local record = player ~= nil and partition:GetPlayer(player) or nil
        local card = record and describe(inputs, player, record.main) or describe(inputs, nil, player)
        card.count = entries[index].count or 0
        card.countText = card.count .. "×"
        table.insert(mostGrouped, card)
    end
    local slots = addon.FellowshipStore.FRIEND_SLOTS
    local selected
    local _, list
    for _, list in ipairs({ friends, mostGrouped }) do
        for index = 1, #list do
            if list[index].playerId == inputs.selected then
                selected = inputs.selected
            end
        end
    end
    local first = friends[1] or mostGrouped[1]
    return {
        friends = friends,
        empty = math.max(0, slots - #friends),
        full = #friends >= slots,
        mostGrouped = mostGrouped,
        selected = selected,
        default = first and first.playerId or nil,
    }
end

-- Whether `query` (lowercase, not empty) is in the player's alias or any of
-- their characters' names.
local function matches(row, query, partition)
    if string.find(lower(row.alias), query, 1, true) ~= nil then
        return true
    end
    local index
    for index = 1, #row.keys do
        local character = partition:GetCharacter(row.keys[index]) or {}
        if string.find(lower(character.name or row.keys[index]), query, 1, true) ~= nil then
            return true
        end
    end
    return false
end

-- The picker's rows: the inputs as for Build, plus
--   selfKey   the user's own character key, whose player is left out
--   statsOf   function(key) -> how many parties the user was in with that
--             character's player, and when the last was
--   query     what the user typed (matched, ignoring case, against the
--             alias and every character name)
-- Each row is a card (see Build) plus key (the character to pin: the main
-- when it's in the guild, else the first one that is), alts, count and
-- grouped ("12× grouped" or "Never grouped").
function FriendsViewModel.Picker(inputs)
    local partition = inputs.partition
    local excluded = {}
    local selfPlayer = inputs.selfKey and playerOf(partition, inputs.selfKey) or nil
    if selfPlayer ~= nil then
        excluded[selfPlayer] = true
    end
    local keys = inputs.friendKeys or {}
    local index
    for index = 1, #keys do
        excluded[playerOf(partition, keys[index]) or keys[index]] = true
    end
    local query = lower(inputs.query)
    query = string.match(query, "^%s*(.-)%s*$")
    local rows = {}
    partition:EachPlayer(function(playerId)
        if excluded[playerId] then
            return
        end
        local characters = partition:CharactersOf(playerId)
        local inGuild = {}
        local characterIndex
        for characterIndex = 1, #characters do
            if partition:IsInGuild(characters[characterIndex]) then
                table.insert(inGuild, characters[characterIndex])
            end
        end
        if inGuild[1] == nil then
            return
        end
        local row = describe(inputs, playerId, inGuild[1])
        if query ~= "" and not matches(row, query, partition) then
            return
        end
        row.alts = #inGuild - 1
        row.count = ask(inputs.statsOf, inGuild[1])
        if type(row.count) ~= "number" then
            row.count = 0
        end
        row.grouped = row.count > 0 and (row.count .. "× grouped") or FriendsViewModel.NEVER_GROUPED
        table.insert(rows, row)
    end)
    table.sort(rows, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        if lower(a.name) ~= lower(b.name) then
            return lower(a.name) < lower(b.name)
        end
        return tostring(a.playerId) < tostring(b.playerId)
    end)
    return rows
end
