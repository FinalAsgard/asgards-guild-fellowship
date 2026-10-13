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
addon.ProfileViewModel = ProfileViewModel

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
        isSelf = isSelf,
        roles = roles,
        rolesText = addon.RoleCatalog.Describe(preferences),
        -- Role preferences change only on the character they belong to.
        editable = isSelf,
        hint = not isSelf and ("Log in on " .. name .. " to change its roles.") or nil,
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
-- Returns { message, dnd } when there's no player to show, or:
--   { label, alias, mainName, characters, dnd }
-- where `characters` lists the main first, then the alts still in the
-- guild, each:
--   { key, name, coloredName, level, isMain, isSelf, roles, rolesText,
--     editable, hint }
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
    return {
        label = player.alias and (player.alias .. " (" .. main.name .. ")") or main.name,
        alias = player.alias,
        mainName = main.name,
        characters = characters,
        dnd = dnd,
    }
end
