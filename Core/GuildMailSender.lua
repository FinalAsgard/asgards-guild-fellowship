local _, addon = ...

-- Sends a list of Guild Mails one at a time. The game ignores a new mail
-- until it has answered the last one (MAIL_SEND_SUCCESS or MAIL_FAILED), so
-- the next mail goes out only after OnSent or OnFailed for the one in
-- flight, and a moment later (GAP_SECONDS): a mail sent straight from the
-- answer to the last one went nowhere in game. Answers that arrive with
-- nothing in flight (the player sending a mail of their own) are ignored.
--
-- When the game doesn't answer within ANSWER_SECONDS, or blocks the send,
-- sending pauses on that mail. Resume (from a click on Send next) sends it
-- again; the game always takes a mail sent from a click. After one pause,
-- every later mail also waits for a click, since the game would likely
-- stall again. An answer that turns up late still counts.
--
-- Some mails the game refuses at once with only an error message (a
-- one-word name on a client with two-part names), never answering
-- MAIL_FAILED; and a MAIL_FAILED is followed by the error that says why.
-- OnError takes either: an error soon after a send fails that mail, and one
-- right after a failure gives its reason.
--
-- Pure: the game call and the timer are injected.
--   send(mail) -> true when the client took the mail; `mail` is one of the
--                 list given to Start ({ to, subject, body })
--   after(seconds, callback) -> true when the timer was set; without a
--                 timer the next mail goes out at once and nothing times out
--   onChange() -> called after every change of progress
local GuildMailSender = {
    IDLE = "idle",
    SENDING = "sending",
    PAUSED = "paused",
    DONE = "done",
    PENDING = "pending",
    SENT = "sent",
    FAILED = "failed",
    REFUSED = "the game didn't take the mail",
    GAP_SECONDS = 1,
    ANSWER_SECONDS = 10,
    -- An error this soon after a send is taken to be about that mail.
    ERROR_SECONDS = 2,
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
        after = options.after or function()
            return false
        end,
        onChange = options.onChange or function() end,
        mails = {},
        statuses = {},
        reasons = {},
        state = GuildMailSender.IDLE,
        current = nil,
        inFlight = false,
        fresh = false,
        lastFailed = nil,
        manual = false,
        attempt = 0,
    }, Sender)
end

-- True while a send is under way, paused or not.
function Sender:IsSending()
    return self.state == GuildMailSender.SENDING or self.state == GuildMailSender.PAUSED
end

function Sender:IsPaused()
    return self.state == GuildMailSender.PAUSED
end

-- Whether every mail now waits for a click (after the game stalled once).
function Sender:IsManual()
    return self.manual
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
    self.current = 1
    self.inFlight = false
    self.manual = false
    self:sendCurrent()
    return true
end

function Sender:changed()
    pcall(self.onChange)
end

-- Runs `callback` after `seconds`, or at once without a timer. Each timer
-- belongs to one attempt, so a stale one does nothing.
function Sender:later(seconds, callback)
    local attempt = self.attempt
    local ok, set = pcall(self.after, seconds, function()
        if self.attempt == attempt then
            callback()
        end
    end)
    return ok and set == true
end

-- Sends the current mail. One the client won't take is marked failed at
-- once and the next one is tried.
function Sender:sendCurrent()
    while self.current ~= nil and self.current <= #self.mails do
        self.attempt = self.attempt + 1
        self.lastFailed = nil
        local ok, taken = pcall(self.send, self.mails[self.current])
        if ok and taken then
            self.inFlight = true
            self.fresh = true
            self.state = GuildMailSender.SENDING
            self:later(GuildMailSender.ANSWER_SECONDS, function()
                self:pause()
            end)
            self:later(GuildMailSender.ERROR_SECONDS, function()
                self.fresh = false
            end)
            self:changed()
            return
        end
        self.statuses[self.current] = GuildMailSender.FAILED
        self.reasons[self.current] = GuildMailSender.REFUSED
        self.current = self.current + 1
    end
    self:finishAll()
end

function Sender:finishAll()
    self.current = nil
    self.inFlight = false
    self.state = GuildMailSender.DONE
    self:changed()
end

-- Waits for a click on Send next before the current mail goes (again).
-- A mail that may still be on its way stays in flight, so a late answer
-- counts.
function Sender:pause()
    if not self:IsSending() or self.current == nil then
        return
    end
    self.attempt = self.attempt + 1
    self.manual = true
    self.state = GuildMailSender.PAUSED
    self:changed()
end

-- Moves on to the next mail: after a click when manual, else a moment
-- after this answer.
function Sender:advance()
    self.attempt = self.attempt + 1
    self.inFlight = false
    self.current = self.current + 1
    if self.current > #self.mails then
        self:finishAll()
        return
    end
    if self.manual then
        self.state = GuildMailSender.PAUSED
        self:changed()
        return
    end
    self.state = GuildMailSender.SENDING
    self:changed()
    if not self:later(GuildMailSender.GAP_SECONDS, function()
        self:sendCurrent()
    end) then
        self:sendCurrent()
    end
end

function Sender:finish(status, reason)
    -- A late answer to a paused mail still counts: it did go.
    if not self:IsSending() or self.current == nil or not self.inFlight then
        return false
    end
    self.statuses[self.current] = status
    self.reasons[self.current] = reason
    local finished = self.current
    self:advance()
    if status == GuildMailSender.FAILED then
        self.lastFailed = finished
    end
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

-- The game blocked the add-on's send: wait for a click.
function Sender:OnBlocked()
    if not self.inFlight then
        return false
    end
    -- A blocked mail never went.
    self.inFlight = false
    self:pause()
    return true
end

-- The game showed an error `message`. Soon after a send, it fails that
-- mail with the message as its reason; right after a failure without a
-- reason, it becomes that failure's reason. Returns true when it was used.
function Sender:OnError(message)
    if type(message) ~= "string" or message == "" then
        return false
    end
    if self.inFlight and self.fresh then
        return self:finish(GuildMailSender.FAILED, message)
    end
    if self.lastFailed ~= nil and self.reasons[self.lastFailed] == nil then
        self.reasons[self.lastFailed] = message
        self:changed()
        return true
    end
    return false
end

-- Sends the paused mail now (call it from a click). Returns false when
-- nothing is paused.
function Sender:Resume()
    if not self:IsPaused() then
        return false
    end
    self:sendCurrent()
    return true
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
