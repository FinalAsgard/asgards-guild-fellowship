local _, addon = ...

-- Who in the guild could fill each role of a dungeon group. One entry per
-- Fellowship player who is online right now (any of their characters),
-- with their alias, the character they're on and its zone, and every
-- character of theirs that fits: a level within the dungeon's range, a
-- class that can fill the role, and the role on in that character's
-- preferences. Offline alts count, since the player can log over.
--
-- Players whose add-on replied to the Group Finder's ask are add-on users;
-- one that replied as unavailable (Do Not Disturb, in a group or in an
-- instance) is left out. Everyone else online is "no add-on": their
-- preferences can't be trusted to be current, so their class's roles are
-- used alone. The organizer's own player and anyone already in the party
-- are left out too.
--
-- Pure: the guild's facts are handed in.
--   partition  the Fellowship store partition
--   members    live roster facts by key ({ online, zone, level, name })
--   roles      the client's RoleCatalog
--   replies    replies to the last ask by key ({ available } each); a
--              reply's key is the character the replier was on
--   excluded   a set of character keys whose players are left out (the
--              organizer and the party)
--   display    optional function(name) -> the name as shown
local GroupCandidates = {}
addon.GroupCandidates = GroupCandidates

local Candidates = {}
Candidates.__index = Candidates

function GroupCandidates.Create(inputs)
    local candidates = setmetatable({
        partition = inputs.partition,
        members = inputs.members or {},
        roles = inputs.roles,
        replies = inputs.replies or {},
        excluded = inputs.excluded or {},
        display = inputs.display or function(name)
            return name
        end,
    }, Candidates)
    candidates.players = candidates:onlinePlayers()
    return candidates
end

function Candidates:nameOf(key)
    local live = self.members[key]
    local character = self.partition:GetCharacter(key)
    local name = (live and live.name) or (character and character.name) or key
    return self.display(name) or name
end

function Candidates:levelOf(key)
    local live = self.members[key]
    local character = self.partition:GetCharacter(key)
    return (live and live.level) or (character and character.level)
end

-- Every player with a character online now who isn't left out, each
-- { id, label, current = { key, name, zone }, addon, characters }.
function Candidates:onlinePlayers()
    local partition = self.partition
    local seen, players = {}, {}
    local key, live
    for key, live in pairs(self.members) do
        local character = live.online and partition:GetCharacter(key)
        if character and not seen[character.player] then
            seen[character.player] = true
            local entry = self:playerEntry(character.player, key)
            if entry ~= nil then
                table.insert(players, entry)
            end
        end
    end
    table.sort(players, function(a, b)
        if a.addon ~= b.addon then
            return a.addon
        end
        if a.label ~= b.label then
            return a.label < b.label
        end
        return a.id < b.id
    end)
    return players
end

-- The entry for player `id`, on character `onlineKey`, or nil when they're
-- left out.
function Candidates:playerEntry(id, onlineKey)
    local partition = self.partition
    local keys = partition:CharactersOf(id)
    local reply
    local index
    for index = 1, #keys do
        if self.excluded[keys[index]] then
            return nil
        end
        reply = reply or self.replies[keys[index]]
    end
    if reply ~= nil and not reply.available then
        return nil
    end
    local player = partition:GetPlayer(id)
    local characters = {}
    for index = 1, #keys do
        local key = keys[index]
        if partition:IsInGuild(key) then
            table.insert(characters, {
                key = key,
                name = self:nameOf(key),
                level = self:levelOf(key),
                class = partition:GetCharacter(key).class,
                online = self.members[key] ~= nil and self.members[key].online == true,
            })
        end
    end
    table.sort(characters, function(a, b)
        return a.name < b.name
    end)
    local mainName = self:nameOf(player.main)
    return {
        id = id,
        label = player.alias or mainName,
        current = {
            key = onlineKey,
            name = self:nameOf(onlineKey),
            class = partition:GetCharacter(onlineKey).class,
            zone = self.members[onlineKey] and self.members[onlineKey].zone,
        },
        addon = reply ~= nil,
        characters = characters,
    }
end

-- Whether `character` of `player` would play `role` in `dungeon`.
function Candidates:fits(player, character, role, dungeon)
    if type(character.level) ~= "number" or character.level < dungeon.minLevel
        or character.level > dungeon.maxLevel or not self.roles:Can(character.class, role)
    then
        return false
    end
    if not player.addon then
        return true
    end
    local preferences = self.roles:PreferencesOf(self.partition, character.key) or {}
    local index
    for index = 1, #preferences do
        if preferences[index] == role then
            return true
        end
    end
    return false
end

-- The players who could fill `role` in `dungeon` ({ minLevel, maxLevel }),
-- each its player entry with `fitting`, the characters that fit.
function Candidates:ForRole(role, dungeon)
    local found = {}
    local index
    for index = 1, #self.players do
        local player = self.players[index]
        local fitting = {}
        local characterIndex
        for characterIndex = 1, #player.characters do
            local character = player.characters[characterIndex]
            if self:fits(player, character, role, dungeon) then
                table.insert(fitting, character)
            end
        end
        if fitting[1] ~= nil then
            table.insert(found, {
                id = player.id,
                label = player.label,
                current = player.current,
                addon = player.addon,
                fitting = fitting,
            })
        end
    end
    return found
end

-- For each role still open (`openRoles`, a list), in role order:
-- { role, players = ForRole(role, dungeon) }. Filled roles get none.
function Candidates:Suggestions(dungeon, openRoles)
    local open = {}
    local index
    for index = 1, #openRoles do
        open[openRoles[index]] = true
    end
    local lists = {}
    for index = 1, #addon.RoleCatalog.ROLES do
        local role = addon.RoleCatalog.ROLES[index]
        if open[role] then
            table.insert(lists, { role = role, players = self:ForRole(role, dungeon) })
        end
    end
    return lists
end

-- Nearby: guildmates online in `zone` (a zone name), at any level and
-- whatever their availability, one entry per player, sorted by label:
-- { id, label, characters = { { name, level } } } with the characters of
-- theirs online there. The player of `selfKey` is left out.
function Candidates:Nearby(zone, selfKey)
    local partition = self.partition
    local own = selfKey and partition:GetCharacter(selfKey)
    local byPlayer, entries = {}, {}
    local key, live
    for key, live in pairs(self.members) do
        local character = live.online and zone ~= nil and live.zone == zone and partition:GetCharacter(key)
        if character and not (own and character.player == own.player) then
            local entry = byPlayer[character.player]
            if entry == nil then
                local player = partition:GetPlayer(character.player)
                entry = { id = character.player, label = player.alias or self:nameOf(player.main), characters = {} }
                byPlayer[character.player] = entry
                table.insert(entries, entry)
            end
            table.insert(entry.characters, { name = self:nameOf(key), level = self:levelOf(key), class = character.class })
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

-- A character's name in its class color, when `colorOf(class)` gives one
-- ("ffrrggbb").
local function colored(name, class, colorOf)
    local color = colorOf and class and colorOf(class)
    if type(color) ~= "string" then
        return name
    end
    return "|c" .. color .. name .. "|r"
end
GroupCandidates.Colored = colored

-- "Thunderer — Bolt 22", each character in its class color.
function GroupCandidates.DescribeNearby(entry, colorOf)
    local characters = {}
    local index
    for index = 1, #entry.characters do
        local character = entry.characters[index]
        characters[index] = colored(character.name, character.class, colorOf) .. " " .. tostring(character.level or "?")
    end
    return entry.label .. " — " .. table.concat(characters, ", ")
end

-- "Bolt 22, Hammer 24": the player's characters that fit, each name in
-- its class color. Where they are now is Location's.
function GroupCandidates.Describe(entry, colorOf)
    local characters = {}
    local index
    for index = 1, #entry.fitting do
        local character = entry.fitting[index]
        characters[index] = colored(character.name, character.class, colorOf) .. " " .. tostring(character.level)
    end
    return table.concat(characters, ", ")
end

-- "On Bolt, Ironforge": the character the player is on, and where.
function GroupCandidates.Location(entry, colorOf)
    local text = "On " .. colored(entry.current.name, entry.current.class, colorOf)
    if entry.current.zone ~= nil then
        text = text .. ", " .. entry.current.zone
    end
    return text
end
