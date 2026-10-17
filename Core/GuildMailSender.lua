local _, addon = ...

-- Sends a list of Guild Mails one at a time. The game ignores a new mail
-- until it has answered the last one (MAIL_SEND_SUCCESS or MAIL_FAILED), so
-- the next mail goes out only after OnSent or OnFailed for the one in
-- flight. Answers that arrive with nothing in flight (the player sending a
-- mail of their own) are ignored.
--
-- Pure: the game call is injected.
--   send(mail) -> true when the client took the mail; `mail` is one of the
--                 list given to Start ({ to, subject, body })
--   onChange() -> called after every change of progress
local GuildMailSender = {
    IDLE = "idle",
    SENDING = "sending",
    DONE = "done",
    PENDING = "pending",
    SENT = "sent",
    FAILED = "failed",
    REFUSED = "the game didn't take the mail",
}
addon.GuildMailSender = GuildMailSender

local Sender = {}
Sender.__index = Sender

function GuildMailSender.Create(options)
    options = options or {}
    return setmetatable({
        send = options.send or function()
            return false
        end,
        onChange = options.onChange or function() end,
        mails = {},
        statuses = {},
        reasons = {},
        state = GuildMailSender.IDLE,
        current = nil,
    }, Sender)
end

function Sender:IsSending()
    return self.state == GuildMailSender.SENDING
end

-- Starts sending `mails`, a list of { to, subject, body }. Returns false
-- when a send is already under way or there is nothing to send.
function Sender:Start(mails)
    if self:IsSending() or type(mails) ~= "table" or #mails == 0 then
        return false
    end
    self.mails = mails
    self.statuses, self.reasons = {}, {}
    local index
    for index = 1, #mails do
        self.statuses[index] = GuildMailSender.PENDING
    end
    self.state = GuildMailSender.SENDING
    self.current = nil
    self:advance()
    return true
end

-- Sends the next pending mail. A mail the client won't take is marked
-- failed at once and the next one is tried.
function Sender:advance()
    local index = (self.current or 0) + 1
    while index <= #self.mails do
        self.current = index
        local ok, taken = pcall(self.send, self.mails[index])
        if ok and taken then
            self:changed()
            return
        end
        self.statuses[index] = GuildMailSender.FAILED
        self.reasons[index] = GuildMailSender.REFUSED
        index = index + 1
    end
    self.current = nil
    self.state = GuildMailSender.DONE
    self:changed()
end

function Sender:changed()
    pcall(self.onChange)
end

function Sender:finish(status, reason)
    if not self:IsSending() or self.current == nil then
        return false
    end
    self.statuses[self.current] = status
    self.reasons[self.current] = reason
    self:advance()
    return true
end

-- The game confirmed the mail in flight.
function Sender:OnSent()
    return self:finish(GuildMailSender.SENT, nil)
end

-- The game rejected the mail in flight; `reason` is shown with it.
function Sender:OnFailed(reason)
    return self:finish(GuildMailSender.FAILED, reason)
end

-- { sent, failed, total, state }.
function Sender:Progress()
    local sent, failed = 0, 0
    local index
    for index = 1, #self.mails do
        if self.statuses[index] == GuildMailSender.SENT then
            sent = sent + 1
        elseif self.statuses[index] == GuildMailSender.FAILED then
            failed = failed + 1
        end
    end
    return { sent = sent, failed = failed, total = #self.mails, state = self.state }
end

-- The status of mail `index` ("pending", "sent" or "failed") and, for a
-- failed one, why.
function Sender:Status(index)
    return self.statuses[index], self.reasons[index]
end
