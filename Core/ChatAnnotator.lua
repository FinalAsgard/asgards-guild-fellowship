local _, addon = ...

-- Adds the speaker's player tag to guild and officer chat lines, so
-- "[Hammer]: hi" reads "[Hammer] [TheTool]: hi", and to guild achievement
-- announcements: "[Hammer] [TheTool] has earned the achievement …".
-- Pure: it reads the Fellowship database
-- through `context` and never touches the game. Only the message text
-- changes; the sender and its name link are left alone. Any failure leaves
-- the message as it was.
local ChatAnnotator = {
    -- The chat events that get tags.
    EVENTS = { "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_GUILD_ACHIEVEMENT" },
    -- Tag colors by kind: an alias is green, a main's name light blue, so a
    -- nickname and a character name are told apart at a glance.
    COLORS = {
        alias = "ff7fff7f",
        main = "ff7fd4ff",
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
function ChatAnnotator.Create(options)
    return setmetatable({
        context = options.context,
        isSecret = options.isSecret or function()
            return false
        end,
    }, Annotator)
end

-- True when either value is hidden from add-ons, or the check itself fails:
-- then the line is left alone rather than risk touching a hidden value.
function Annotator:IsHidden(message, sender)
    local ok, hidden = pcall(function()
        return self.isSecret(message) or self.isSecret(sender)
    end)
    return not ok or hidden == true
end

-- The speaker's tag ({ text, kind }), or nil.
function Annotator:TagFor(sender)
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
-- client hides from add-ons is checked first and never touched.
function Annotator:Annotate(event, message, sender)
    if not TAGGED_EVENTS[event] or self:IsHidden(message, sender) then
        return nil
    end
    if type(message) ~= "string" or type(sender) ~= "string" then
        return nil
    end
    local nameEnd
    if event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
        nameEnd = select(2, string.find(message, "%s", 1, true))
        if nameEnd == nil then
            return nil
        end
    end
    local ok, tag = pcall(self.TagFor, self, sender)
    if not ok or tag == nil then
        return nil
    end
    if nameEnd ~= nil then
        return string.sub(message, 1, nameEnd) .. " " .. ChatAnnotator.Format(tag) .. string.sub(message, nameEnd + 1)
    end
    return ChatAnnotator.Format(tag) .. " " .. message
end

-- A tag as chat shows it: "[TheTool]" in its kind's color. A "|" in the text
-- is doubled so the chat frame shows it literally instead of reading it as
-- an escape code.
function ChatAnnotator.Format(tag)
    local text = string.gsub(tag.text, "|", "||")
    return "|c" .. ChatAnnotator.COLORS[tag.kind] .. "[" .. text .. "]|r"
end
