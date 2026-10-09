local _, addon = ...

-- Guild Greet: turns guild members coming online into greet prompts, and a
-- press of Greet into one random greeting in guild chat. It wires
-- GreetPolicy (who gets a prompt), GreetPromptQueue (what's waiting), and
-- GreetingLibrary (what to say) to the game through the functions it's
-- given, so it never touches the game itself. Nothing is ever posted
-- without the user pressing Greet.
local GuildGreet = {}
addon.GuildGreet = GuildGreet

local Greet = {}
Greet.__index = Greet

-- options:
--   context       function() -> partition, normalizer, or nil
--   selfKey       function() -> the logged-in character's key, or nil
--   store         function() -> the FellowshipStore, or nil
--   now           function() -> seconds
--   after         function(seconds, callback) -> false when there's no timer
--   random        function(low, high) -> a whole number
--   send          function(text) -> true when posted to guild chat
--   view          { Show = function(view, prompts, handlers) }: draws the
--                 prompts; handlers.greet(player) and handlers.close(player)
function GuildGreet.Create(options)
    local greet = setmetatable({
        context = options.context,
        selfKey = options.selfKey,
        store = options.store,
        now = options.now,
        after = options.after,
        random = options.random,
        send = options.send,
        view = options.view,
        queue = addon.GreetPromptQueue.Create(),
        -- Hours since each offline member's last login, as the roster said
        -- when the session's roster first loaded.
        absences = {},
    }, Greet)
    greet.policy = addon.GreetPolicy.Create({
        playerOf = function(key)
            return (greet:service():PlayerOf(key))
        end,
        isMember = function(key)
            local partition = greet.context()
            return partition ~= nil and partition:IsInGuild(key)
        end,
        isOwn = function(key)
            return greet:IsOwn(key)
        end,
        absenceOf = function(key)
            return greet:AbsenceOf(key)
        end,
        enabled = function()
            return greet:IsEnabled()
        end,
    })
    return greet
end

-- A PlayerService over the current guild, or nil.
function Greet:service()
    local partition, normalizer = self.context()
    if partition == nil then
        return nil
    end
    return addon.PlayerService.Create(partition, { normalizer = normalizer })
end

function Greet:IsEnabled()
    local store = self.store()
    return store == nil or store:GreetEnabled()
end

-- True for any of the user's own characters.
function Greet:IsOwn(key)
    local selfKey = self.selfKey()
    if selfKey == nil then
        return false
    end
    if selfKey == key then
        return true
    end
    local service = self:service()
    local ownPlayer = service and service:PlayerOf(selfKey)
    return ownPlayer ~= nil and ownPlayer == service:PlayerOf(key)
end

-- The first and last words of a two-part (Forever) name, or the whole name
-- twice on Retail, where names are one word. `display` is the name as shown,
-- used when the name can't be split.
local function nameParts(normalizer, rawName, display)
    if normalizer == nil or not normalizer.twoPartNames then
        return display, display
    end
    local name = normalizer:Split(rawName)
    if name == nil then
        return display, display
    end
    return string.match(name, "^(%S+)"), string.match(name, "(%S+)$")
end

-- The texts for a greeting's placeholders, keyed in lowercase:
--   name                         the alias, else the main's name, else the
--                                character's
--   main, mainfirst, mainlast    the main's name and its first and last
--                                parts
--   character, characterfirst,   the character that logged in, as the game
--   characterlast                spells it, and its first and last parts
-- First and last parts only differ on Forever's two-part names. A character
-- the database doesn't know is its own main.
function Greet:Names(key, rawName)
    local partition, normalizer = self.context()
    local character = normalizer and normalizer:Display(rawName) or rawName
    local characterFirst, characterLast = nameParts(normalizer, rawName, character)
    local names = {
        name = character,
        character = character, characterfirst = characterFirst, characterlast = characterLast,
        main = character, mainfirst = characterFirst, mainlast = characterLast,
    }
    if partition == nil then
        return names
    end
    local service = addon.PlayerService.Create(partition, { normalizer = normalizer })
    local _, player = service:PlayerOf(key)
    local mainRecord = player and partition:GetCharacter(player.main)
    if mainRecord ~= nil then
        names.main = service:CharacterName(player.main) or character
        names.mainfirst, names.mainlast = nameParts(normalizer, mainRecord.name or player.main, names.main)
    end
    names.name = player and player.alias or names.main
    return names
end

-- Whole hours since the roster's last-online time ({ years, months, days,
-- hours }), counting a month as 30 days and a year as 12 months.
function GuildGreet.HoursAway(lastOnline)
    if type(lastOnline) ~= "table" then
        return nil
    end
    local months = (lastOnline.years or 0) * 12 + (lastOnline.months or 0)
    return (months * 30 + (lastOnline.days or 0)) * 24 + (lastOnline.hours or 0)
end

-- Seconds between the player's latest login on any of their characters and
-- the start of the session, from the roster as it first loaded; nil when
-- none of their characters was in it.
function Greet:AbsenceOf(key)
    local keys = { key }
    local service = self:service()
    local playerId = service and service:PlayerOf(key)
    if playerId ~= nil then
        keys = service:CharactersOf(playerId)
    end
    local shortest
    local index
    for index = 1, #keys do
        local hours = self.absences[keys[index]]
        if hours ~= nil and (shortest == nil or hours < shortest) then
            shortest = hours
        end
    end
    return shortest and shortest * 3600 or nil
end

-- Called on every roster update. The first one with a loaded roster tells
-- the policy who was already online, and records how long everyone else has
-- been away. `readRoster()` returns the members ({ name, online, lastOnline
-- }), or nil while the roster is still loading.
function Greet:OnRosterUpdate(readRoster)
    if self.policy:IsReady() then
        return
    end
    local _, normalizer = self.context()
    local members = normalizer and readRoster()
    if members == nil then
        return
    end
    local online = {}
    local index
    for index = 1, #members do
        local member = members[index]
        local key = normalizer:Key(member.name)
        if key ~= nil and member.online then
            table.insert(online, key)
        elseif key ~= nil then
            self.absences[key] = GuildGreet.HoursAway(member.lastOnline)
        end
    end
    self.policy:Seed(online)
end

-- A guild member came online ("online"), went offline ("offline"), or
-- someone joined the guild ("join").
-- `rawName` is the name the game's message reported.
function Greet:OnPresence(kind, rawName)
    local _, normalizer = self.context()
    local key = normalizer and normalizer:Key(rawName)
    local now = self.now()
    if key == nil or type(now) ~= "number" then
        return
    end
    if kind == "offline" then
        self.policy:WentOffline(key, now)
        return
    end
    local prompt
    if kind == "online" then
        prompt = self.policy:CameOnline(key, now)
    elseif kind == "join" then
        prompt = self.policy:Joined(key, now)
    end
    if prompt == nil then
        return
    end
    prompt.rawName = rawName
    prompt.label = self:Names(key, rawName).name
    local expiresAt = self.queue:Add(prompt, now)
    -- Redraw when it expires, so it leaves the screen on time.
    self.after(expiresAt - now, function()
        self:Refresh()
    end)
    self:Refresh()
end

-- Draws the waiting prompts.
function Greet:Refresh()
    local now = self.now()
    if type(now) ~= "number" or self.view == nil then
        return
    end
    pcall(self.view.Show, self.view, self.queue:Visible(now), {
        greet = function(player)
            self:Greet(player)
        end,
        close = function(player)
            self:Close(player)
        end,
    })
end

-- The user pressed Greet: posts a random greeting from the prompt's
-- category, using the names as they are now. Returns the text sent, or nil.
function Greet:Greet(player)
    local prompt = self.queue:Get(player)
    if prompt == nil then
        return nil
    end
    self.queue:Remove(player)
    local store = self.store()
    local library = addon.GreetingLibrary.Create(store and store:GetGreetState(), self.random)
    local greeting = library:Pick(prompt.category)
    local text
    if greeting ~= nil then
        text = addon.GreetingLibrary.Render(greeting, self:Names(prompt.key, prompt.rawName))
        if not self.send(text) then
            text = nil
        end
    end
    self:Refresh()
    return text
end

-- The user closed a prompt without greeting.
function Greet:Close(player)
    self.queue:Remove(player)
    self:Refresh()
end

-- Guild Greet was turned on or off. Turning it off clears waiting prompts.
function Greet:OnEnabledChanged(enabled)
    if not enabled then
        self.queue:Clear()
        self:Refresh()
    end
end
