local _, addon = ...

-- Guild Mail: an officer ticks guild ranks, writes a subject and body once,
-- reviews who will get it, confirms, and the mails go out one at a time
-- (GuildMailSender). Recipients come from GuildMailAudience. Only officers
-- can open it, and mail is only sent with a mailbox open; away from one the
-- officer can still compose and review.
--
-- It holds the window's state and works out what the window shows
-- (Model); the window only draws that and passes clicks and typing back.
--
-- options:
--   context     function() -> the current guild's partition, or nil
--   selfKey     function() -> the logged-in character's key, or nil
--   isOfficer   function() -> true when the logged-in character is an
--               officer (OfficerAuthority)
--   rankNames   function() -> the guild's rank names, a list where entry 1
--               is rank 0 (the guild master's), or nil
--   live        function() -> live roster facts by character key
--               ({ online, lastOnline }), or nil
--   send        function(to, subject, body) -> true when the client took
--               the mail
--   after       function(seconds, callback) -> true when the timer was set
--               (pacing, and noticing when the game doesn't answer)
--   testers     TEMPORARY (#205): character names a "Tester" rank mails,
--               so Guild Mail can be tried without mailing the guild
--   view        optional window: Show(fromMailbox), Render(model),
--               IsShown()
local GuildMail = {
    OFFICERS_ONLY = "Guild Mail is for officers.",
    NO_GUILD = "Guild Mail needs a guild.",
    HINT_SENDING = "Sending...",
    HINT_PAUSED = "The game didn't send the last mail on its own. Press Send next for each mail.",
    SEND_TEXT = "Send",
    SEND_NEXT_TEXT = "Send next",
    HINT_NO_RANKS = "Tick at least one rank.",
    HINT_NOBODY = "Nobody in those ranks to mail.",
    HINT_NO_SUBJECT = "Write a subject.",
    HINT_NO_MAILBOX = "Open a mailbox to send.",
    ONLINE_TEXT = "Online",
    -- TEMPORARY (#205): the pretend rank that mails only the testers.
    TESTER_RANK = -1,
    TESTER_RANK_NAME = "Tester (temporary)",
    -- The Send to choices, in the order shown.
    MODES = {
        { id = "mains", label = "Mains only" },
        { id = "recent", label = "Most recently online character" },
        { id = "all", label = "Every character" },
    },
}
addon.GuildMail = GuildMail

local Mail = {}
Mail.__index = Mail

local function blank(text)
    return type(text) ~= "string" or string.match(text, "^%s*$") ~= nil
end

local function plural(count, one, many)
    return count .. " " .. (count == 1 and one or many)
end

function GuildMail.Create(options)
    options = options or {}
    local mail = setmetatable({
        context = options.context or function()
            return nil
        end,
        selfKey = options.selfKey or function()
            return nil
        end,
        isOfficer = options.isOfficer or function()
            return false
        end,
        rankNames = options.rankNames or function()
            return nil
        end,
        live = options.live or function()
            return nil
        end,
        sendMail = options.send or function()
            return false
        end,
        view = options.view,
        testers = options.testers or {},
        ranks = {},
        mode = addon.GuildMailAudience.MAINS,
        subject = "",
        body = "",
        mailboxOpen = false,
        confirming = false,
        batch = nil,
    }, Mail)
    mail.sender = addon.GuildMailSender.Create({
        send = function(item)
            return mail.sendMail(item.to, item.subject, item.body)
        end,
        after = options.after,
        onChange = function()
            mail:refresh()
        end,
    })
    return mail
end

function Mail:IsOfficer()
    local ok, officer = pcall(self.isOfficer)
    return ok and officer == true
end

-- Whether the mailbox shows the Guild Mail button: officers only.
function Mail:ShowsMailboxButton()
    return self:IsOfficer()
end

-- Opens the window (beside the mailbox when `fromMailbox`). Returns false
-- and a reason for a non-officer or outside a guild.
function Mail:Open(fromMailbox)
    if not self:IsOfficer() then
        return false, GuildMail.OFFICERS_ONLY
    end
    if self.context() == nil then
        return false, GuildMail.NO_GUILD
    end
    if self.view ~= nil then
        pcall(self.view.Show, self.view, fromMailbox == true)
    end
    self:refresh()
    return true
end

-- Redraws the window, e.g. to put a control back that was clicked to no
-- effect.
function Mail:Refresh()
    self:refresh()
end

function Mail:refresh()
    if self.view == nil then
        return
    end
    local ok, shown = pcall(self.view.IsShown, self.view)
    if ok and shown then
        pcall(self.view.Render, self.view, self:Model())
    end
end

-- A finished send stays on show until the officer changes something; then
-- the list is worked out afresh. Nothing changes while mails are going out.
function Mail:editable()
    if self.sender:IsSending() then
        return false
    end
    self.batch = nil
    self.confirming = false
    return true
end

function Mail:SetRank(index, checked)
    checked = checked and true or nil
    if type(index) ~= "number" or self.ranks[index] == checked or not self:editable() then
        return false
    end
    self.ranks[index] = checked
    self:refresh()
    return true
end

-- Chooses who in each player gets the mail: "mains", "recent" or "all".
function Mail:SetMode(mode)
    local known = false
    local index
    for index = 1, #GuildMail.MODES do
        known = known or GuildMail.MODES[index].id == mode
    end
    if not known or mode == self.mode or not self:editable() then
        return false
    end
    self.mode = mode
    self:refresh()
    return true
end

function Mail:SetSubject(text)
    text = type(text) == "string" and text or ""
    if text == self.subject or not self:editable() then
        return false
    end
    self.subject = text
    self:refresh()
    return true
end

function Mail:SetBody(text)
    text = type(text) == "string" and text or ""
    if text == self.body or not self:editable() then
        return false
    end
    self.body = text
    self:refresh()
    return true
end

function Mail:OnMailboxOpened()
    self.mailboxOpen = true
    self:refresh()
end

function Mail:OnMailboxClosed()
    self.mailboxOpen = false
    self.confirming = false
    self:refresh()
end

-- The rank list: { index, name, checked } for every rank, highest first.
-- Without names from the client, the ranks seen in the roster are listed as
-- "Rank N".
function Mail:rankList(partition)
    local ok, names = pcall(self.rankNames)
    local list = {}
    if ok and type(names) == "table" and #names > 0 then
        local index
        for index = 1, #names do
            table.insert(list, { index = index - 1, name = tostring(names[index]) })
        end
    elseif partition ~= nil then
        local seen = {}
        partition:EachCharacter(function(key, character)
            if type(character.rank) == "number" and partition:IsInGuild(key) then
                seen[character.rank] = true
            end
        end)
        local rank
        for rank in pairs(seen) do
            table.insert(list, { index = rank, name = "Rank " .. (rank + 1) })
        end
        table.sort(list, function(first, second)
            return first.index < second.index
        end)
    end
    -- TEMPORARY (#205): the Tester rank comes first.
    if #self.testers > 0 then
        table.insert(list, 1, { index = GuildMail.TESTER_RANK, name = GuildMail.TESTER_RANK_NAME })
    end
    local index
    for index = 1, #list do
        list[index].checked = self.ranks[list[index].index] == true
    end
    return list
end

-- Who would get the mail now.
function Mail:Recipients()
    local partition = self.context()
    if partition == nil then
        return {}
    end
    local ok, live = pcall(self.live)
    local recipients = addon.GuildMailAudience.Recipients(partition, {
        ranks = self.ranks,
        mode = self.mode,
        live = ok and type(live) == "table" and live or nil,
        selfKey = self.selfKey(),
    })
    -- TEMPORARY (#205): the Tester rank mails exactly the testers, first,
    -- whatever Send to says.
    if self.ranks[GuildMail.TESTER_RANK] then
        local listed = {}
        local index
        for index = 1, #recipients do
            listed[string.lower(recipients[index].name)] = true
        end
        for index = #self.testers, 1, -1 do
            local name = self.testers[index]
            if not listed[string.lower(name)] then
                table.insert(recipients, 1, {
                    key = name, name = name, playerName = name, rank = GuildMail.TESTER_RANK,
                })
            end
        end
    end
    return recipients
end

-- Why Send can't be pressed now, or nil when it can.
function Mail:hint(recipients)
    if self.sender:IsPaused() then
        return self.mailboxOpen and GuildMail.HINT_PAUSED or GuildMail.HINT_NO_MAILBOX
    end
    if self.sender:IsSending() then
        return GuildMail.HINT_SENDING
    end
    if next(self.ranks) == nil then
        return GuildMail.HINT_NO_RANKS
    end
    if #recipients == 0 then
        return GuildMail.HINT_NOBODY
    end
    if blank(self.subject) then
        return GuildMail.HINT_NO_SUBJECT
    end
    if not self.mailboxOpen then
        return GuildMail.HINT_NO_MAILBOX
    end
    return nil
end

-- A finished send has to be changed before it can go again, so the same
-- mail is never sent twice by accident.
function Mail:CanSend()
    return self.batch == nil and self:IsOfficer() and self:hint(self:Recipients()) == nil
end

-- Asks for confirmation before sending. Returns false when Send can't be
-- pressed now.
-- While sending is paused (the game didn't send a mail on its own), Send
-- next sends the next mail at once: from a click, the game takes it.
function Mail:RequestSend()
    if self.sender:IsPaused() then
        return self.mailboxOpen and self.sender:Resume()
    end
    if not self:CanSend() then
        return false
    end
    self.confirming = true
    self:refresh()
    return true
end

function Mail:Cancel()
    self.confirming = false
    self:refresh()
end

-- Sends to everyone on the list, one mail at a time.
function Mail:Confirm()
    if not self.confirming then
        return false
    end
    self.confirming = false
    if not self:CanSend() then
        self:refresh()
        return false
    end
    local recipients = self:Recipients()
    local mails = {}
    local index
    for index = 1, #recipients do
        mails[index] = { to = recipients[index].name, subject = self.subject, body = self.body }
    end
    self.batch = recipients
    return self.sender:Start(mails)
end

-- MAIL_SEND_SUCCESS and MAIL_FAILED, passed on to the sender.
function Mail:OnSent()
    return self.sender:OnSent()
end

function Mail:OnFailed(reason)
    return self.sender:OnFailed(reason)
end

-- The game blocked the add-on's SendMail: wait for Send next.
function Mail:OnBlocked()
    return self.sender:OnBlocked()
end

function Mail:IsSending()
    return self.sender:IsSending()
end

function Mail:progressText()
    if self.batch == nil then
        return nil
    end
    local progress = self.sender:Progress()
    local text = "Sent " .. progress.sent .. " of " .. progress.total
    if progress.failed > 0 then
        text = text .. ", " .. progress.failed .. " failed"
    end
    if progress.state == addon.GuildMailSender.DONE then
        text = text .. ". Done."
    end
    return text
end

-- "Online", "3 days ago", or "" when the live roster doesn't say.
local function lastSeen(recipient)
    if recipient.online then
        return GuildMail.ONLINE_TEXT
    end
    return addon.RosterViewModel.FormatLastOnline(recipient.lastOnline) or ""
end

-- What the window shows:
--   ranks        { index, name, checked } for every rank
--   modes        { id, label, checked } for each Send to choice
--   subject, body
--   recipients   { name, playerName, rank, rankName, lastSeen, status,
--                reason }; status is nil
--                until a send starts, then "pending", "sent" or "failed"
--   countText    "12 mails"
--   canSend      whether Send can be pressed
--   sendText     "Send", or "Send next" while paused
--   hint         why it can't, or nil
--   confirming   whether the confirmation is up, with confirmText
--   progressText "Sent 3 of 12", or nil before a send
--   sending      whether mails are going out
function Mail:Model()
    local partition = self.context()
    local ranks = self:rankList(partition)
    local rankNames = {}
    local index
    for index = 1, #ranks do
        rankNames[ranks[index].index] = ranks[index].name
    end
    local recipients = self.batch or self:Recipients()
    local rows = {}
    for index = 1, #recipients do
        local status, reason
        if self.batch ~= nil then
            status, reason = self.sender:Status(index)
        end
        rows[index] = {
            name = recipients[index].name,
            playerName = recipients[index].playerName,
            lastSeen = lastSeen(recipients[index]),
            rank = recipients[index].rank,
            rankName = rankNames[recipients[index].rank] or ("Rank " .. (recipients[index].rank + 1)),
            status = status,
            reason = reason,
        }
    end
    local hint = self:hint(recipients)
    local officer = self:IsOfficer()
    local modes = {}
    for index = 1, #GuildMail.MODES do
        modes[index] = {
            id = GuildMail.MODES[index].id,
            label = GuildMail.MODES[index].label,
            checked = GuildMail.MODES[index].id == self.mode,
        }
    end
    return {
        ranks = ranks,
        modes = modes,
        subject = self.subject,
        body = self.body,
        recipients = rows,
        countText = plural(#rows, "mail", "mails"),
        canSend = officer and ((hint == nil and self.batch == nil)
            or (self.sender:IsPaused() and self.mailboxOpen)),
        sendText = self.sender:IsPaused() and GuildMail.SEND_NEXT_TEXT or GuildMail.SEND_TEXT,
        hint = hint,
        confirming = self.confirming,
        confirmText = "Send " .. plural(#rows, "mail", "mails") .. "?",
        progressText = self:progressText(),
        sending = self.sender:IsSending(),
    }
end
