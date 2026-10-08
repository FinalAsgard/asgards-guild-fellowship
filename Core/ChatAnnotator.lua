local _, addon = ...

-- Adds the speaker's player tag to guild chat lines, so "[Hammer]: hi"
-- reads "[Hammer] [TheTool]: hi". Pure: it reads the Fellowship database
-- through `context` and never touches the game. Only the message text
-- changes; the sender and its name link are left alone. Any failure leaves
-- the message as it was.
local ChatAnnotator = {
    -- The chat events that get tags.
    EVENTS = { "CHAT_MSG_GUILD" },
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
function ChatAnnotator.Create(options)
    return setmetatable({ context = options.context }, Annotator)
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

-- The message with the speaker's tag in front, or nil to leave it unchanged.
-- `sender` is the raw name the chat event reports.
function Annotator:Annotate(event, message, sender)
    if not TAGGED_EVENTS[event] or type(message) ~= "string" or type(sender) ~= "string" then
        return nil
    end
    local ok, tag = pcall(self.TagFor, self, sender)
    if not ok or tag == nil then
        return nil
    end
    return "[" .. tag.text .. "] " .. message
end
