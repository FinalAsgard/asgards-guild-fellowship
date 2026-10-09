local _, addon = ...

-- The user's greetings, by category, kept in Guild Greet's saved state
-- (FellowshipStore:GetGreetState). Every category starts with the starter
-- greetings the first time it's used. Picking a greeting never repeats the
-- one used last in that category when there is another to choose, and the
-- last one used is saved so that holds across sessions.
--
-- Greetings may use {name} (the player's alias, else their main's name,
-- else the character's name) and {character} (the character that logged
-- in). Anything else in braces is left as written.
local GreetingLibrary = {
    -- One guild chat message holds at most this many characters.
    MAX_LENGTH = 255,
    STARTERS = {
        join = {
            "Welcome to the guild, {name}!",
            "Welcome aboard, {name}! Glad to have you.",
            "Hey {name}, welcome! Shout if you need anything.",
        },
        login = {
            "Hey {name}!",
            "Hi {name}, good to see you!",
            "Evening, {name}!",
        },
        welcomeBack = {
            "Welcome back, {name}!",
            "WB {name}!",
            "Look who's back, {name}!",
        },
        longAbsence = {
            "{name}! Long time no see, welcome back!",
            "Look who it is! Good to have you back, {name}!",
            "{name}! It's been ages, welcome back!",
        },
    },
}
addon.GreetingLibrary = GreetingLibrary

local Library = {}
Library.__index = Library

local function copy(list)
    local result = {}
    local index
    for index = 1, #list do
        result[index] = list[index]
    end
    return result
end

-- `state` is Guild Greet's saved state, or nil when saved data is
-- unavailable (then there are no greetings). `random(low, high)` picks a
-- whole number.
function GreetingLibrary.Create(state, random)
    return setmetatable({
        state = state,
        random = random or function(low)
            return low
        end,
    }, Library)
end

-- A greeting cleaned for chat: trimmed, with line breaks folded to spaces,
-- and cut to one message. Nil when nothing is left.
function GreetingLibrary.Clean(text)
    if type(text) ~= "string" then
        return nil
    end
    text = string.gsub(text, "[\r\n]+", " ")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then
        return nil
    end
    return string.sub(text, 1, GreetingLibrary.MAX_LENGTH)
end

-- Fills in a greeting's placeholders. `names.name` and `names.character` are
-- the texts to use. The result is cut to one chat message.
function GreetingLibrary.Render(text, names)
    names = names or {}
    local rendered = string.gsub(text, "{(%a+)}", function(placeholder)
        local value = names[placeholder]
        if type(value) == "string" then
            return value
        end
        return nil
    end)
    return string.sub(rendered, 1, GreetingLibrary.MAX_LENGTH)
end

-- The saved greetings table, created (with the starters) on first use. Nil
-- when saved data is unavailable or the stored value is unusable.
function Library:stored()
    if type(self.state) ~= "table" then
        return nil
    end
    if self.state.greetings == nil then
        local greetings = {}
        local category, starters
        for category, starters in pairs(GreetingLibrary.STARTERS) do
            greetings[category] = copy(starters)
        end
        self.state.greetings = greetings
    end
    if type(self.state.greetings) ~= "table" then
        return nil
    end
    return self.state.greetings
end

-- A category's greetings, cleaned. Empty when there are none, or the
-- category or its saved list is unusable.
function Library:Greetings(category)
    local greetings = self:stored()
    local starters = GreetingLibrary.STARTERS[category]
    if greetings == nil or starters == nil then
        return {}
    end
    if greetings[category] == nil then
        greetings[category] = copy(starters)
    end
    local saved = greetings[category]
    if type(saved) ~= "table" then
        return {}
    end
    local result = {}
    local index
    for index = 1, #saved do
        local cleaned = GreetingLibrary.Clean(saved[index])
        if cleaned ~= nil then
            table.insert(result, cleaned)
        end
    end
    return result
end

-- Picks a greeting from `category` at random, never the one used last time
-- when there's another. Returns the greeting (placeholders unfilled), or nil
-- when the category has none.
function Library:Pick(category)
    local greetings = self:Greetings(category)
    if #greetings == 0 then
        return nil
    end
    local lastUsed = self.state.lastUsed
    if type(lastUsed) ~= "table" then
        lastUsed = nil
    end
    local choices = greetings
    if #greetings > 1 and lastUsed ~= nil then
        choices = {}
        local index
        for index = 1, #greetings do
            if greetings[index] ~= lastUsed[category] then
                table.insert(choices, greetings[index])
            end
        end
        if #choices == 0 then
            choices = greetings
        end
    end
    local ok, chosen = pcall(self.random, 1, #choices)
    if not ok or type(chosen) ~= "number" or choices[chosen] == nil then
        chosen = 1
    end
    local greeting = choices[chosen]
    if self.state.lastUsed == nil then
        self.state.lastUsed = {}
        lastUsed = self.state.lastUsed
    end
    if lastUsed ~= nil then
        lastUsed[category] = greeting
    end
    return greeting
end
