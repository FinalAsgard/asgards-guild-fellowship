local _, addon = ...

-- Adds the speaker's player tag to guild and officer chat lines, so
-- "[Hammer]: hi" reads "[Hammer] [TheTool]: hi", and to guild achievement
-- announcements: "[Hammer] [TheTool] has earned the achievement …".
-- Pure: it reads the Fellowship database
-- through `context` and never touches the game. Only the message text
-- changes; the sender and its name link are left alone. Any failure leaves
-- the message as it was.
local ChatAnnotator = {
    -- How many recent chat lines' results are kept, so a line shown in
    -- several chat tabs is worked out once.
    RECENT_LINES = 16,
    -- The chat events that get tags.
    EVENTS = { "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_GUILD_ACHIEVEMENT" },
    -- Default tag colors by kind, as "rrggbb": an alias is medium blue, a
    -- main's name light blue, so a nickname and a character name are told
    -- apart at a glance. A member can choose others (see `colorFor`).
    COLORS = {
        alias = "4a90ff",
        main = "7fd4ff",
    },
    -- The colors offered for a tag, all easy to read on guild chat's green
    -- and officer chat's darker green; both defaults are among them.
    SWATCHES = {
        { label = "Blue", color = "4a90ff" },
        { label = "Light blue", color = "7fd4ff" },
        { label = "Purple", color = "b48cff" },
        { label = "Pink", color = "ff7fbf" },
        { label = "Red", color = "ff5050" },
        { label = "Orange", color = "ff9933" },
        { label = "Gold", color = "ffd100" },
        { label = "White", color = "ffffff" },
        { label = "Grey", color = "a0a0a0" },
    },
}
addon.ChatAnnotator = ChatAnnotator

local TAGGED_EVENTS = {}
local eventIndex
for eventIndex = 1, #ChatAnnotator.EVENTS do
    TAGGED_EVENTS[ChatAnnotator.EVENTS[eventIndex]] = true
end

local Annotator = {}
Annotator.__index = Annotator

-- options.context: function() -> partition, normalizer for the current
-- guild, or nil when there's none yet (no guild, guild info not loaded,
-- saved data unavailable).
-- options.isSecret: function(value) -> true when the client hides `value`
-- from add-ons (Retail does during encounters and keystone runs). Optional;
-- without it nothing is secret.
-- options.enabled: function() -> false when the player turned tags off.
-- Optional; without it tags are on.
-- options.colorFor: function(kind) -> the chosen "rrggbb" color for a kind
-- of tag, or nil for the default. Optional.
-- options.revision: function() -> a value that changes whenever what tags
-- are worked out from (aliases, mains) may have: each speaker's tag is kept
-- until it does. Optional; without it tags are worked out every time.
function ChatAnnotator.Create(options)
    return setmetatable({
        context = options.context,
        revision = options.revision,
        tags = {},
        lines = {},
        nextLine = 1,
        colorFor = options.colorFor or function()
            return nil
        end,
        enabled = options.enabled or function()
            return true
        end,
        isSecret = options.isSecret or function()
            return false
        end,
    }, Annotator)
end

-- Whether the player has tags on. A setting that can't be read leaves the
-- line alone.
function Annotator:IsEnabled()
    local ok, enabled = pcall(self.enabled)
    return ok and enabled ~= false
end

-- True when either value is hidden from add-ons, or the check itself fails:
-- then the line is left alone rather than risk touching a hidden value.
function Annotator:IsHidden(message, sender)
    local ok, hidden = pcall(function()
        return self.isSecret(message) or self.isSecret(sender)
    end)
    return not ok or hidden == true
end

local function bump(name)
    if addon.PerfCounters ~= nil then
        addon.PerfCounters.Bump(name)
    end
end

-- The speaker's tag ({ text, kind }), or nil, kept per speaker until the
-- revision changes.
function Annotator:CachedTagFor(sender)
    if self.revision == nil then
        return self:TagFor(sender)
    end
    local revision = self.revision()
    if revision ~= self.tagsRevision then
        self.tags = {}
        self.tagsRevision = revision
    end
    local cached = self.tags[sender]
    if cached ~= nil then
        bump("chatTagHits")
        return cached.tag
    end
    local tag = self:TagFor(sender)
    self.tags[sender] = { tag = tag }
    return tag
end

-- The speaker's tag ({ text, kind }), or nil.
function Annotator:TagFor(sender)
    bump("chatTags")
    local partition, normalizer = self.context()
    if partition == nil or normalizer == nil then
        return nil
    end
    local key = normalizer:Key(sender)
    if key == nil then
        return nil
    end
    return addon.PlayerService.Create(partition, { normalizer = normalizer }):ChatTag(key)
end

-- The message with the speaker's tag added, or nil to leave it unchanged.
-- `sender` is the raw name the chat event reports. A chat line gets the tag
-- in front of its text. An achievement message is a template whose "%s" the
-- chat frame replaces with the speaker's name link, so the tag goes right
-- after it; a template without one is left alone. A message or sender the
-- client hides from add-ons is checked first and never touched. `lineId`,
-- the chat line's ID when the client gives one, lets a line shown in
-- several chat tabs be worked out once.
function Annotator:Annotate(event, message, sender, lineId)
    if not TAGGED_EVENTS[event] or not self:IsEnabled() or self:IsHidden(message, sender)
        or (lineId ~= nil and self:IsHidden(lineId, lineId))
    then
        return nil
    end
    if type(message) ~= "string" or type(sender) ~= "string" then
        return nil
    end
    if type(lineId) ~= "number" then
        return self:annotate(event, message, sender)
    end
    local index
    for index = 1, #self.lines do
        local line = self.lines[index]
        if line.id == lineId and line.event == event and line.message == message and line.sender == sender then
            bump("chatTagHits")
            return line.result
        end
    end
    local result = self:annotate(event, message, sender)
    self.lines[self.nextLine] = { id = lineId, event = event, message = message, sender = sender, result = result }
    self.nextLine = self.nextLine % ChatAnnotator.RECENT_LINES + 1
    return result
end

function Annotator:annotate(event, message, sender)
    local nameEnd
    if event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
        nameEnd = select(2, string.find(message, "%s", 1, true))
        if nameEnd == nil then
            return nil
        end
    end
    local ok, tag = pcall(self.CachedTagFor, self, sender)
    if not ok or tag == nil then
        return nil
    end
    local colorOk, color = pcall(self.colorFor, tag.kind)
    local formatted = ChatAnnotator.Format(tag, colorOk and color or nil)
    if nameEnd ~= nil then
        -- The chat frame formats the template, so a "%" in the tag is
        -- doubled to stay literal.
        formatted = string.gsub(formatted, "%%", "%%%%")
        return string.sub(message, 1, nameEnd) .. " " .. formatted .. string.sub(message, nameEnd + 1)
    end
    return formatted .. " " .. message
end

-- A tag as chat shows it: "[TheTool]" in `color` ("rrggbb"), or its kind's
-- default color when `color` isn't one. A "|" in the text is doubled so the
-- chat frame shows it literally instead of reading it as an escape code.
function ChatAnnotator.Format(tag, color)
    if type(color) ~= "string" or string.find(color, "^%x%x%x%x%x%x$") == nil then
        color = ChatAnnotator.COLORS[tag.kind]
    end
    local text = string.gsub(tag.text, "|", "||")
    return "|cff" .. color .. "[" .. text .. "]|r"
end
