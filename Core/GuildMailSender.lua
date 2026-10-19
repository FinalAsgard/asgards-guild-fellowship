local _, addon = ...

-- Sends a list of Guild Mails one at a time. The game ignores a new mail
-- until it has answered the last one (MAIL_SEND_SUCCESS or MAIL_FAILED), so
-- the next mail goes out only after OnSent or OnFailed for the one in
-- flight, and a moment later (GAP_SECONDS): a mail sent straight from the
-- answer to the last one went nowhere in game. Answers that arrive with
-- nothing in flight (the player sending a mail of their own) are ignored.
--
-- When the game doesn't answer within ANSWER_SECONDS, that mail fails
-- ("no response") and sending moves on; it's tried once more at the end of
-- the list, and fails for good if the game doesn't answer then either.
--
-- When the game blocks the send, sending pauses on that mail. Resume (from
-- a click on Send next) sends it again; the game always takes a mail sent
-- from a click. After one pause, every later mail also waits for a click,
-- since the game would likely block again.
--
-- Restore picks up a send saved before a reload: the pending mails wait for
-- Resume. A mail that was in flight comes back unconfirmed and is passed
-- over until Settle sends it again (pending once more) or skips it.
--
-- Stop halts sending: at once when nothing is in flight, else as soon as
-- the game answers the mail in flight. Resume then carries on with the
-- mails still pending, so nobody is mailed twice; End gives up on them.
--
-- Some mails the game refuses at once with only an error message (a
-- one-word name on a client with two-part names), never answering
-- MAIL_FAILED; and a MAIL_FAILED is followed by the error that says why.
-- OnError takes either: an error soon after a send fails that mail, and one
-- right after a failure gives its reason.
--
-- The game caps how many different characters can be mailed in a while
-- (about 19). Its cap error, either way it comes, pauses sending instead:
-- the refused mail stays pending and goes first on Resume, which pauses
-- again if the cap is still in force. Nobody is failed for it.
--
-- Pure: the game call and the timer are injected.
--   send(mail) -> true when the client took the mail; `mail` is one of the
--                 list given to Start ({ to, subject, body })
--   after(seconds, callback) -> true when the timer was set; without a
--                 timer the next mail goes out at once and nothing times out
--   onChange() -> called after every change of progress
--   capMessage    optional: the client's own text for the cap error
local GuildMailSender = {
    IDLE = "idle",
    SENDING = "sending",
    PAUSED = "paused",
    STOPPED = "stopped",
    DONE = "done",
    PENDING = "pending",
    SENT = "sent",
    FAILED = "failed",
    -- A restored mail that was waiting for an answer when the game closed:
    -- nobody knows whether it went, so it's never sent again on its own.
    UNCONFIRMED = "unconfirmed",
    -- An unconfirmed mail the officer chose not to send again.
    SKIPPED = "skipped",
    REFUSED = "the game didn't take the mail",
    NO_RESPONSE = "no response",
    NO_RESPONSE_RETRY = "no response, will try again at the end",
    GAP_SECONDS = 1,
    ANSWER_SECONDS = 10,
    -- An error this soon after a send is taken to be about that mail.
    ERROR_SECONDS = 2,
    -- The cap error as the English client shows it, for a client that
    -- doesn't give its own text.
    CAP_MESSAGE = "You have reached the in-game cap of unique mail recipients",
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
        capMessage = options.capMessage,
        mails = {},
        -- The mails to send, as indexes into `mails`, in order; a mail
        -- with no answer is added again at the end, once.
        queue = {},
        position = nil,
        retried = {},
        statuses = {},
        reasons = {},
        state = GuildMailSender.IDLE,
        current = nil,
        inFlight = false,
        fresh = false,
        lastFailed = nil,
        manual = false,
        stopping = false,
        capped = false,
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

-- True after Stop, until Resume or End.
function Sender:IsStopped()
    return self.state == GuildMailSender.STOPPED
end

-- True after Stop while the mail in flight is still to be answered.
function Sender:IsStopping()
    return self.stopping and self.state == GuildMailSender.SENDING
end

-- True while paused or stopped by the game's cap on recipients.
function Sender:IsCapped()
    return self.capped and (self:IsPaused() or self:IsStopped())
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
    self.statuses, self.reasons, self.queue, self.retried = {}, {}, {}, {}
    local index
    for index = 1, #mails do
        self.statuses[index] = GuildMailSender.PENDING
        self.queue[index] = index
    end
    self.state = GuildMailSender.SENDING
    self.position = 1
    self.current = 1
    self.inFlight = false
    self.manual = false
    self.stopping = false
    self.capped = false
    self:sendCurrent()
    return true
end

-- Picks up a send saved before a reload: `mails` as given to Start, with
-- each one's status and reason. Pending mails wait for Resume (a pause
-- when `capped`, else a stop); unconfirmed ones wait to be settled.
-- Returns false while a send is under way or with nothing to restore.
function Sender:Restore(mails, statuses, reasons, capped)
    if self:IsSending() or type(mails) ~= "table" or #mails == 0 then
        return false
    end
    self.attempt = self.attempt + 1
    self.mails = mails
    self.statuses, self.reasons, self.queue, self.retried = {}, {}, {}, {}
    local index
    for index = 1, #mails do
        local status = type(statuses) == "table" and statuses[index] or nil
        if status ~= GuildMailSender.SENT and status ~= GuildMailSender.FAILED
            and status ~= GuildMailSender.UNCONFIRMED and status ~= GuildMailSender.SKIPPED
        then
            status = GuildMailSender.PENDING
        end
        self.statuses[index] = status
        self.reasons[index] = type(reasons) == "table" and type(reasons[index]) == "string" and reasons[index] or nil
        if status == GuildMailSender.PENDING then
            table.insert(self.queue, index)
        end
    end
    self.inFlight = false
    self.fresh = false
    self.lastFailed = nil
    self.manual = false
    self.stopping = false
    self.capped = false
    if #self.queue == 0 then
        self.current = nil
        self.position = nil
        self.state = GuildMailSender.DONE
    else
        self.position = 1
        self.current = self.queue[1]
        self.capped = capped == true
        self.state = self.capped and GuildMailSender.PAUSED or GuildMailSender.STOPPED
    end
    self:changed()
    return true
end

-- Settles unconfirmed mail `index`: `send` makes it pending again, to go
-- with the rest on Resume (a finished send is stopped again for it); else
-- it's skipped. Returns false when that mail isn't unconfirmed.
function Sender:Settle(index, send)
    if self.statuses[index] ~= GuildMailSender.UNCONFIRMED then
        return false
    end
    if not send then
        self.statuses[index] = GuildMailSender.SKIPPED
        self:changed()
        return true
    end
    self.statuses[index] = GuildMailSender.PENDING
    self.reasons[index] = nil
    if self.position == nil then
        self.queue = { index }
        self.position = 1
        self.current = index
        self.stopping = false
        self.state = GuildMailSender.STOPPED
    else
        table.insert(self.queue, index)
    end
    self:changed()
    return true
end

-- The mail waiting for the game's answer, or nil.
function Sender:InFlight()
    if self.inFlight then
        return self.current
    end
    return nil
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
    while self.position ~= nil and self.position <= #self.queue do
        self.current = self.queue[self.position]
        local attempt = self.attempt + 1
        self.attempt = attempt
        self.lastFailed = nil
        -- In flight before the call: the game reports a blocked send (and
        -- some refusals) while SendMail is still running.
        self.inFlight = true
        self.fresh = true
        self.state = GuildMailSender.SENDING
        -- A mail being tried again is pending once more.
        self.statuses[self.current] = GuildMailSender.PENDING
        self.reasons[self.current] = nil
        local ok, taken = pcall(self.send, self.mails[self.current])
        if self.attempt ~= attempt then
            -- An event during the call already dealt with this mail.
            return
        end
        if ok and taken then
            self:later(GuildMailSender.ANSWER_SECONDS, function()
                self:noAnswer()
            end)
            self:later(GuildMailSender.ERROR_SECONDS, function()
                self.fresh = false
            end)
            self:changed()
            return
        end
        self.inFlight = false
        self.fresh = false
        self.statuses[self.current] = GuildMailSender.FAILED
        self.reasons[self.current] = GuildMailSender.REFUSED
        self.position = self.position + 1
    end
    self:finishAll()
end

-- The game didn't answer the mail in flight in time: it fails, is queued
-- to be tried once more at the end, and sending moves on.
function Sender:noAnswer()
    if not self.inFlight then
        return
    end
    local reason = GuildMailSender.NO_RESPONSE
    if not self.retried[self.current] then
        self.retried[self.current] = true
        table.insert(self.queue, self.current)
        reason = GuildMailSender.NO_RESPONSE_RETRY
    end
    self:finish(GuildMailSender.FAILED, reason)
end

function Sender:finishAll()
    self.current = nil
    self.position = nil
    self.inFlight = false
    self.state = GuildMailSender.DONE
    self:changed()
end

-- Waits for a click on Send next before the current mail goes (again).
function Sender:pause()
    if not self:IsSending() or self.current == nil then
        return
    end
    self.attempt = self.attempt + 1
    self.manual = true
    self.state = self.stopping and GuildMailSender.STOPPED or GuildMailSender.PAUSED
    self:changed()
end

-- Stops sending: now when no mail is in flight, else once the game
-- answers it (or doesn't, in time). Returns false when nothing is being
-- sent.
function Sender:Stop()
    if not self:IsSending() then
        return false
    end
    self.stopping = true
    if not self.inFlight or self:IsPaused() then
        self.attempt = self.attempt + 1
        self.state = GuildMailSender.STOPPED
    end
    self:changed()
    return true
end

-- Gives up on the mails still pending after Stop: sending is done, and
-- they stay pending. A mail waiting to be tried again won't be, so it
-- fails for good. Returns false when not stopped.
function Sender:End()
    if not self:IsStopped() then
        return false
    end
    self.attempt = self.attempt + 1
    self.stopping = false
    local index
    for index = 1, #self.mails do
        if self.reasons[index] == GuildMailSender.NO_RESPONSE_RETRY then
            self.reasons[index] = GuildMailSender.NO_RESPONSE
        end
    end
    self:finishAll()
    return true
end

-- Moves on to the next mail: after a click when manual, else a moment
-- after this answer.
function Sender:advance()
    self.attempt = self.attempt + 1
    self.inFlight = false
    self.position = self.position + 1
    if self.position > #self.queue then
        self:finishAll()
        return
    end
    self.current = self.queue[self.position]
    if self.stopping then
        self.state = GuildMailSender.STOPPED
        self:changed()
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
    -- A late answer to a paused or stopped mail still counts: it did go.
    if not (self:IsSending() or self:IsStopped()) or self.current == nil or not self.inFlight then
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

-- Whether `message` is the game's cap error: its own text when given,
-- else the English one, ignoring case and a closing full stop.
function Sender:isCap(message)
    local texts = { self.capMessage, GuildMailSender.CAP_MESSAGE }
    local lowered = string.lower(message)
    local index
    for index = 1, #texts do
        if type(texts[index]) == "string" then
            local text = string.lower(string.gsub(texts[index], "%.%s*$", ""))
            if text ~= "" and string.find(lowered, text, 1, true) then
                return true
            end
        end
    end
    return false
end

-- The cap refused mail `index`: it's pending again and goes first on
-- Resume, and sending pauses (or, after Stop, stays stopped).
function Sender:capReached(index)
    self.attempt = self.attempt + 1
    self.inFlight = false
    self.fresh = false
    self.lastFailed = nil
    self.statuses[index] = GuildMailSender.PENDING
    self.reasons[index] = nil
    if self.current ~= index then
        -- Sending already moved past it: put it back in front.
        local position = self.position or (#self.queue + 1)
        table.insert(self.queue, position, index)
        self.position = position
        self.current = index
    end
    self.capped = true
    self.state = self.stopping and GuildMailSender.STOPPED or GuildMailSender.PAUSED
    self:changed()
    return true
end

-- The game showed an error `message`. Soon after a send, it fails that
-- mail with the message as its reason; right after a failure without a
-- reason, it becomes that failure's reason. The cap error instead pauses
-- on that mail. Returns true when it was used.
function Sender:OnError(message)
    if type(message) ~= "string" or message == "" then
        return false
    end
    if self:isCap(message) then
        if self.inFlight and self.fresh then
            return self:capReached(self.current)
        end
        if self.lastFailed ~= nil then
            return self:capReached(self.lastFailed)
        end
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

-- Sends the paused mail now (call it from a click), or carries on after
-- Stop with the mails still pending. Returns false when neither.
function Sender:Resume()
    if not (self:IsPaused() or self:IsStopped()) then
        return false
    end
    self.stopping = false
    self.capped = false
    self:sendCurrent()
    return true
end

-- { sent, failed, unconfirmed, skipped, total, state }.
function Sender:Progress()
    local counts = { sent = 0, failed = 0, unconfirmed = 0, skipped = 0 }
    local index
    for index = 1, #self.mails do
        local status = self.statuses[index]
        if counts[status] ~= nil then
            counts[status] = counts[status] + 1
        end
    end
    counts.total = #self.mails
    counts.state = self.state
    return counts
end

-- The status of mail `index` ("pending", "sent", "failed", "unconfirmed"
-- or "skipped") and, for a failed one, why.
function Sender:Status(index)
    return self.statuses[index], self.reasons[index]
end
