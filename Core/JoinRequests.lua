local _, addon = ...

-- The invitee's side of Group Finder requests. Each request from an
-- organizer becomes a prompt listing what the player could bring: one
-- option per role and character, for every role the organizer still has
-- open, that character's preferences allow and its class can fill, and
-- every character of the player's whose level fits the dungeon. Choosing
-- an option or Decline answers the organizer. A request is refused at once
-- while the player is unavailable (Do Not Disturb, in a group or an
-- instance), or when nothing they have fits. A prompt closes when the
-- organizer cancels it or REQUEST_SECONDS pass.
--
-- Pure: the guild's facts are handed in.
--   partition()  -> the Fellowship store partition, or nil
--   roles        the client's RoleCatalog
--   selfKey()    -> the logged-in character's key, or nil
--   members      optional function() -> live roster facts by key, for
--                current levels
--   available()  -> whether the player is available
--   display      optional function(name) -> the name as shown
local JoinRequests = {
    REQUEST_SECONDS = 120,
}
addon.JoinRequests = JoinRequests

local Requests = {}
Requests.__index = Requests

function JoinRequests.Create(options)
    return setmetatable({
        partition = options.partition,
        roles = options.roles,
        selfKey = options.selfKey,
        members = options.members or function()
            return {}
        end,
        available = options.available or function()
            return true
        end,
        display = options.display or function(name)
            return name
        end,
        pending = {},
    }, Requests)
end

-- The options request `message` offers this player, in role order, then by
-- character name: { role, key, name, level } each.
function Requests:OptionsFor(message)
    local partition = self.partition()
    local selfKey = self.selfKey()
    local character = partition and selfKey and partition:GetCharacter(selfKey)
    if character == nil then
        return {}
    end
    local open = {}
    local index
    for index = 1, #message.r do
        open[message.r[index]] = true
    end
    local live = self.members() or {}
    local keys = partition:CharactersOf(character.player)
    local fitting = {}
    for index = 1, #keys do
        local key = keys[index]
        local stored = partition:GetCharacter(key)
        local level = (live[key] and live[key].level) or stored.level
        if partition:IsInGuild(key) and type(level) == "number" and level >= message.lo and level <= message.hi then
            local name = (live[key] and live[key].name) or stored.name or key
            table.insert(fitting, {
                key = key,
                name = self.display(name) or name,
                level = level,
                class = stored.class,
                preferences = self.roles:PreferencesOf(partition, key) or {},
            })
        end
    end
    table.sort(fitting, function(a, b)
        return a.name < b.name
    end)
    local options = {}
    local roleIndex
    for roleIndex = 1, #addon.RoleCatalog.ROLES do
        local role = addon.RoleCatalog.ROLES[roleIndex]
        if open[role] then
            for index = 1, #fitting do
                local candidate = fitting[index]
                local willing = false
                local preference
                for preference = 1, #candidate.preferences do
                    willing = willing or candidate.preferences[preference] == role
                end
                if willing and self.roles:Can(candidate.class, role) then
                    table.insert(options, {
                        role = role, key = candidate.key, name = candidate.name, level = candidate.level,
                    })
                end
            end
        end
    end
    return options
end

-- A request arrived from `organizer` (key) named `sender` at `now`.
-- Returns nil when it becomes a prompt, or "unavailable" / "no fit" when
-- it's refused at once (the caller declines it).
function Requests:OnRequest(message, organizer, sender, now)
    if not self.available() then
        return "unavailable"
    end
    local options = self:OptionsFor(message)
    if options[1] == nil then
        return "no fit"
    end
    -- A repeated request replaces the one it repeats.
    self:Remove(message.id)
    table.insert(self.pending, {
        id = message.id,
        organizer = organizer,
        sender = sender,
        dungeon = { name = message.dn, minLevel = message.lo, maxLevel = message.hi },
        options = options,
        at = now,
    })
    return nil
end

-- Closes prompt `id`. Returns it, or nil.
function Requests:Remove(id)
    local index
    for index = 1, #self.pending do
        if self.pending[index].id == id then
            return table.remove(self.pending, index)
        end
    end
    return nil
end

-- The organizer cancelled request `id`: closes its prompt when `organizer`
-- sent it. Returns whether one closed.
function Requests:OnCancel(id, organizer)
    local index
    for index = 1, #self.pending do
        local prompt = self.pending[index]
        if prompt.id == id and prompt.organizer == organizer then
            table.remove(self.pending, index)
            return true
        end
    end
    return false
end

-- Accepts prompt `id` with its option `choice` (an index). Returns the
-- prompt and the option, or nil.
function Requests:Accept(id, choice)
    local index
    for index = 1, #self.pending do
        local prompt = self.pending[index]
        if prompt.id == id and prompt.options[choice] ~= nil then
            table.remove(self.pending, index)
            return prompt, prompt.options[choice]
        end
    end
    return nil
end

-- Declines prompt `id`. Returns the prompt, or nil.
function Requests:Decline(id)
    return self:Remove(id)
end

-- Closes every prompt open for REQUEST_SECONDS by `now`. Returns those.
function Requests:Expire(now)
    local expired, kept = {}, {}
    local index
    for index = 1, #self.pending do
        local prompt = self.pending[index]
        if now - prompt.at >= JoinRequests.REQUEST_SECONDS then
            table.insert(expired, prompt)
        else
            table.insert(kept, prompt)
        end
    end
    self.pending = kept
    return expired
end

-- The open prompts, oldest first.
function Requests:Pending()
    local copy = {}
    local index
    for index = 1, #self.pending do
        copy[index] = self.pending[index]
    end
    return copy
end

-- "Healer — Hammer (24)".
function JoinRequests.OptionLabel(option)
    return addon.RoleCatalog.LABELS[option.role] .. " — " .. option.name .. " (" .. option.level .. ")"
end
