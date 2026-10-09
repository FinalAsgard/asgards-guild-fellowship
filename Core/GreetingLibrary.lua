local _, addon = ...

-- The user's greetings, by category, kept in Guild Greet's saved state
-- (FellowshipStore:GetGreetState). Every category starts with the starter
-- greetings the first time it's used. Picking a greeting never repeats the
-- one used last in that category when there is another to choose, and the
-- last one used is saved so that holds across sessions.
--
-- Greetings may use {name}, {main}, {mainFirst}, {mainLast}, {character},
-- {characterFirst} and {characterLast}, in any case (GuildGreet:Names says
-- what each holds). Anything else in braces is left as written.
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
            "Hello, {name}!",
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
    -- Starters that were replaced, and what replaces them in saved
    -- greetings that still have the old wording.
    RETIRED = {
        ["Evening, {name}!"] = "Hello, {name}!",
    },
    -- The categories in the order the Greetings window and the settings
    -- panel list them, with the panel's on/off label for each.
    CATEGORIES = {
        { id = "join", label = "Join", when = "Someone joins the guild.",
            toggle = "Prompt when someone joins the guild" },
        { id = "login", label = "Login", when = "Someone's first login you see this session.",
            toggle = "Prompt for first logins" },
        { id = "welcomeBack", label = "Welcome back", when = "Someone you saw log off comes back after a break.",
            toggle = "Prompt for welcome backs" },
        { id = "longAbsence", label = "Long absence", when = "Someone logs in after a long time away.",
            toggle = "Prompt after a long absence" },
    },
    -- Every placeholder and what it's filled with. Case doesn't matter.
    PLACEHOLDERS = {
        { "{name}", "their alias, else their main's name" },
        { "{main}", "their main's name, even when they have an alias" },
        { "{mainFirst}", "the first part of their main's name" },
        { "{mainLast}", "the last part of their main's name" },
        { "{character}", "the character that logged in" },
        { "{characterFirst}", "the first part of that character's name" },
        { "{characterLast}", "the last part of that character's name" },
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

-- Trimmed, with line breaks folded to spaces. Nil when nothing is left.
local function tidy(text)
    if type(text) ~= "string" then
        return nil
    end
    text = string.gsub(text, "[\r\n]+", " ")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if text == "" then
        return nil
    end
    return text
end

-- A greeting cleaned for chat: trimmed, with line breaks folded to spaces,
-- and cut to one message. Nil when nothing is left.
function GreetingLibrary.Clean(text)
    text = tidy(text)
    return text and string.sub(text, 1, GreetingLibrary.MAX_LENGTH)
end

-- A greeting the user typed, tidied the same way. Returns nil and the reason
-- when it's empty or won't fit in one chat message; a long greeting is
-- refused rather than cut, so nothing is silently lost.
function GreetingLibrary.Check(text)
    local tidied = tidy(text)
    if tidied == nil then
        return nil, "it's empty"
    end
    if #tidied > GreetingLibrary.MAX_LENGTH then
        return nil, "it's longer than one guild chat message (" .. GreetingLibrary.MAX_LENGTH .. " characters)"
    end
    return tidied
end

-- Fills in a greeting's placeholders from `names`, keyed in lowercase (see
-- GuildGreet:Names). Placeholders ignore case, so {MainLast} and {mainlast}
-- are the same. The result is cut to one chat message.
function GreetingLibrary.Render(text, names)
    names = names or {}
    local rendered = string.gsub(text, "{(%a+)}", function(placeholder)
        local value = names[string.lower(placeholder)]
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
        if GreetingLibrary.RETIRED[saved[index]] ~= nil then
            saved[index] = GreetingLibrary.RETIRED[saved[index]]
        end
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

-- The category's saved list, rewritten as Greetings(category) shows it so
-- positions match what the user sees. Nil and the reason when it can't be
-- edited; an unusable saved list is left alone.
function Library:editable(category)
    if GreetingLibrary.STARTERS[category] == nil then
        return nil, "there is no such category"
    end
    local greetings = self:stored()
    if greetings == nil then
        return nil, "saved data is unavailable"
    end
    local cleaned = self:Greetings(category)
    if type(greetings[category]) ~= "table" then
        return nil, "the saved greetings are unreadable"
    end
    greetings[category] = cleaned
    return cleaned
end

-- Adds a greeting to the end of `category`. Returns its position, or nil and
-- the reason.
function Library:Add(category, text)
    local list, reason = self:editable(category)
    if list == nil then
        return nil, reason
    end
    local greeting
    greeting, reason = GreetingLibrary.Check(text)
    if greeting == nil then
        return nil, reason
    end
    table.insert(list, greeting)
    return #list
end

-- Replaces the greeting at `index` in `category`. Returns true, or nil and
-- the reason.
function Library:Edit(category, index, text)
    local list, reason = self:editable(category)
    if list == nil then
        return nil, reason
    end
    if list[index] == nil then
        return nil, "that greeting is gone"
    end
    local greeting
    greeting, reason = GreetingLibrary.Check(text)
    if greeting == nil then
        return nil, reason
    end
    list[index] = greeting
    return true
end

-- Deletes the greeting at `index` in `category`. A category may be left
-- empty: it then shows no prompts. Returns true, or nil and the reason.
function Library:Remove(category, index)
    local list, reason = self:editable(category)
    if list == nil then
        return nil, reason
    end
    if list[index] == nil then
        return nil, "that greeting is gone"
    end
    table.remove(list, index)
    return true
end

-- Puts back the starter greetings in `category`, or in every category when
-- it's nil, replacing what's there. Returns true, or nil and the reason.
function Library:Restore(category)
    if category ~= nil and GreetingLibrary.STARTERS[category] == nil then
        return nil, "there is no such category"
    end
    local greetings = self:stored()
    if greetings == nil then
        return nil, "saved data is unavailable"
    end
    local id, starters
    for id, starters in pairs(GreetingLibrary.STARTERS) do
        if category == nil or category == id then
            greetings[id] = copy(starters)
        end
    end
    return true
end
