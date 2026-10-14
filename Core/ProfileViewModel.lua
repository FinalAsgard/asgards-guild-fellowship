local _, addon = ...

-- Builds the My Profile tab: the player of the logged-in character, with
-- its alias, main and alts, each character's role preferences, and Do Not
-- Disturb. Pure: the caller passes the partition, live roster facts, a
-- NameNormalizer, the client's RoleCatalog, and a class color lookup.
local ProfileViewModel = {
    NO_GUILD = "My Profile needs a guild: this character isn't in one.",
    NOT_READY = "Guild information isn't available yet. Try again in a moment.",
    NOT_IN_ROSTER = "This character isn't in the guild roster yet. Try again after the next roster scan.",
}
-- The player's own profile text, in the order it's shown.
ProfileViewModel.ABOUT = {
    { kind = "discord", label = "Discord" },
    { kind = "location", label = "Location" },
    { kind = "bio", label = "Bio" },
}
addon.ProfileViewModel = ProfileViewModel

local candidateEntry

local function coloredName(name, color)
    if type(color) ~= "string" then
        return name
    end
    return "|c" .. color .. name .. "|r"
end

local function characterEntry(inputs, key, isMain)
    local character = inputs.partition:GetCharacter(key)
    local live = inputs.members[key] or {}
    local name = inputs.normalizer:Display(live.name or character.name) or key
    local classToken = live.classToken or character.class
    local isSelf = key == inputs.selfKey
    local preferences = inputs.roles:PreferencesOf(inputs.partition, key) or {}
    local willing = {}
    local index
    for index = 1, #preferences do
        willing[preferences[index]] = true
    end
    -- Only the roles the class can fill are offered.
    local roles = {}
    local classRoles = inputs.roles:RolesFor(classToken)
    for index = 1, #classRoles do
        local role = classRoles[index]
        table.insert(roles, {
            role = role,
            label = addon.RoleCatalog.LABELS[role],
            checked = willing[role] == true,
        })
    end
    return {
        key = key,
        name = name,
        coloredName = coloredName(name, inputs.classColor(classToken)),
        level = live.level or character.level,
        isMain = isMain,
        -- A main the player declared on purpose.
        declared = isMain and inputs.partition:IsDeclared(key),
        isSelf = isSelf,
        roles = roles,
        rolesText = addon.RoleCatalog.Describe(preferences),
        -- Role preferences change only on the character they belong to.
        editable = isSelf,
        hint = not isSelf and ("Log in on " .. name .. " to change its roles.") or nil,
        -- Identity actions, as on the roster: any alt can become the main,
        -- or be removed (split off as its own player).
        canMakeMain = not isMain,
        canRemove = not isMain,
    }
end

-- inputs:
--   inGuild      whether the logged-in character is in a guild
--   partition    the guild's partition, or nil when it isn't available
--   selfKey      the logged-in character's key, or nil
--   members      live roster facts by key (optional)
--   normalizer   a NameNormalizer for the guild
--   roles        the client's RoleCatalog
--   classColor   function(classToken) -> "ffrrggbb" or nil (optional)
--   dnd          whether Do Not Disturb is on
--   pending      this member's pending suggestions (SuggestionService:Pending),
--                optional
-- Returns { message, dnd } when there's no player to show, or:
--   { label, alias, aliasMax, main, mainName, declared, about, characters,
--     suggested, waiting, dnd }
-- where `declared` is whether the player declared its main, and
-- `waiting` lists what this player asked officers for and is still
-- pending (SuggestionBundles.MemberItems), and
-- `alias` is "" without one, `aliasMax` its longest length and `main`
-- the main's key, and
-- `about` lists the player's Discord, location and bio, each
-- { kind, label, text, max } (`text` is "" when not set, `max` the most
-- bytes it may have), and
-- `suggested` lists the other characters this install has logged in on
-- (partition:OwnCharacters) that are in the guild, outside this player and
-- not dismissed, each as AltCandidates describes them; and `characters`
-- lists the main first, then the alts still in the
-- guild, each:
--   { key, name, coloredName, level, isMain, declared, isSelf, roles,
--     rolesText, editable, hint, canMakeMain, canRemove }
-- `roles` lists the roles the character's class can fill, each
-- { role, label, checked }; `editable` is true only for the logged-in
-- character, and the others carry a `hint` saying how to change theirs.
function ProfileViewModel.Build(inputs)
    local dnd = inputs.dnd == true
    if not inputs.inGuild then
        return { message = ProfileViewModel.NO_GUILD, dnd = dnd }
    end
    local partition = inputs.partition
    if not partition then
        return { message = ProfileViewModel.NOT_READY, dnd = dnd }
    end
    local own = inputs.selfKey and partition:GetCharacter(inputs.selfKey)
    local player = own and partition:GetPlayer(own.player)
    if not player then
        return { message = ProfileViewModel.NOT_IN_ROSTER, dnd = dnd }
    end
    inputs.members = inputs.members or {}
    inputs.classColor = inputs.classColor or function()
        return nil
    end

    local main = characterEntry(inputs, player.main, true)
    local characters = { main }
    local keys = partition:CharactersOf(own.player)
    local index
    for index = 1, #keys do
        local key = keys[index]
        if key ~= player.main and partition:IsInGuild(key) then
            table.insert(characters, characterEntry(inputs, key, false))
        end
    end
    local about = {}
    for index = 1, #ProfileViewModel.ABOUT do
        local field = ProfileViewModel.ABOUT[index]
        table.insert(about, {
            kind = field.kind,
            label = field.label,
            text = partition:PlayerProfileText(own.player, field.kind) or "",
            max = addon.FellowshipStore.PROFILE_FIELDS[field.kind],
        })
    end
    local suggested = {}
    local ownKeys = partition:OwnCharacters()
    for index = 1, #ownKeys do
        local key = ownKeys[index]
        local character = partition:GetCharacter(key)
        if character ~= nil and character.player ~= own.player and partition:IsInGuild(key)
            and not partition:IsOwnCharacterDismissed(key)
        then
            table.insert(suggested, candidateEntry(inputs, inputs.members, inputs.classColor, key, character))
        end
    end
    return {
        waiting = addon.SuggestionBundles.MemberItems(partition, inputs.normalizer, own.player, inputs.pending),
        suggested = suggested,
        about = about,
        label = player.alias and (player.alias .. " (" .. main.name .. ")") or main.name,
        alias = player.alias or "",
        aliasMax = addon.PlayerService.MAX_ALIAS_LENGTH,
        main = player.main,
        mainName = main.name,
        declared = main.declared == true,
        characters = characters,
        dnd = dnd,
    }
end

-- A character the player could add as an alt: its name, level and class
-- color, and who it belongs to now when that's another player with more to
-- it (other characters, or an alias).
candidateEntry = function(inputs, members, classColor, key, character)
    local partition = inputs.partition
    local live = members[key] or {}
    local name = inputs.normalizer:Display(live.name or character.name) or key
    local player = partition:GetPlayer(character.player)
    local entry = {
        key = key,
        name = name,
        coloredName = coloredName(name, classColor(live.classToken or character.class)),
        level = live.level or character.level,
    }
    if player ~= nil and (partition:CharactersOf(character.player)[2] ~= nil or player.alias ~= nil) then
        local main = partition:GetCharacter(player.main)
        entry.owner = player.alias or inputs.normalizer:Display(main and main.name or player.main)
        entry.warning = name .. " belongs to " .. entry.owner .. ". Adding it moves it from that player to yours."
    end
    return entry
end

-- Whether player `playerId` is put together: more than one character, or
-- an alias.
local function organized(partition, playerId)
    local player = partition:GetPlayer(playerId)
    return player ~= nil and (partition:CharactersOf(playerId)[2] ~= nil or player.alias ~= nil)
end

-- The guild characters the Add alt picker offers the logged-in character's
-- player: characters still in the guild outside that player whose name, or
-- whose player's alias, contains `query` (any case; an empty query lists
-- them all), sorted by name, at most `limit` (default 50). `inputs` as for
-- Build. Each:
--   { key, name, coloredName, level, owner, joins, warning }
-- `owner` names the player it belongs to now (its alias, else its main)
-- when that player is put together (other characters, or an alias).
-- A player already put together is offered only characters on their own:
-- one of another player's can't be taken from them. A character on its
-- own is also offered other players' characters: picking one `joins` that
-- player, the logged-in character becoming its alt, and `warning` says so.
function ProfileViewModel.AltCandidates(inputs, query, limit)
    local partition = inputs.partition
    local own = partition and inputs.selfKey and partition:GetCharacter(inputs.selfKey)
    if not own then
        return {}
    end
    local alone = not organized(partition, own.player)
    local members = inputs.members or {}
    local classColor = inputs.classColor or function()
        return nil
    end
    local wanted = string.lower(query or "")
    local found = {}
    partition:EachCharacter(function(key, character)
        if character.player == own.player or not partition:IsInGuild(key) then
            return
        end
        local entry = candidateEntry(inputs, members, classColor, key, character)
        if entry.owner ~= nil then
            if not alone then
                return
            end
            local ownName = inputs.normalizer:Display(own.name) or inputs.selfKey
            entry.joins = true
            entry.warning = entry.name .. " belongs to " .. entry.owner .. ". Picking it adds " .. ownName
                .. " to " .. entry.owner .. "'s characters."
        end
        local player = partition:GetPlayer(character.player)
        local searchable = string.lower(entry.name .. " " .. (player and player.alias or ""))
        if wanted == "" or string.find(searchable, wanted, 1, true) ~= nil then
            table.insert(found, entry)
        end
    end)
    table.sort(found, function(first, second)
        return string.lower(first.name) < string.lower(second.name)
    end)
    local results = {}
    local index
    for index = 1, math.min(#found, limit or 50) do
        results[index] = found[index]
    end
    return results
end
