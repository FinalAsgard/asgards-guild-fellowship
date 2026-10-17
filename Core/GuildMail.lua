local _, addon = ...

-- Guild Mail: an officer ticks guild ranks, writes a subject and body once,
-- reviews who will get it (unticking anyone to leave out), confirms, and the mails go out one at a time
-- (GuildMailSender). Recipients come from GuildMailAudience. Only officers
-- can open it, and mail is only sent with a mailbox open; away from one the
-- officer can still compose and review.
--
-- It holds the window's state and works out what the window shows
-- (Model); the window only draws that and passes clicks and typing back.
--
-- The subject and body may use Guild Greet's placeholders, filled in for
-- each recipient (GuildMailComposer). A recipient whose filled-in mail is
-- too long for the game is shown with a warning and can't be ticked.
--
-- options:
--   context     function() -> the current guild's partition and its name
--               normalizer, or nil
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
--   price       function() -> what a text mail costs to send, in copper,
--               at an open mailbox (the game's own price), else nil
--   money       function() -> the officer's money in copper, or nil
--   formatMoney function(copper) -> the game's coin text with icons, or
--               nil to use plain "12s 60c"
--   testers     TEMPORARY (#205): character names a "Tester" rank mails,
--               so Guild Mail can be tried without mailing the guild
--   view        optional window: Show(fromMailbox), Render(model),
--               IsShown()
local GuildMail = {
    OFFICERS_ONLY = "Guild Mail is for officers.",
    NO_GUILD = "Guild Mail needs a guild.",
    HINT_SENDING = "Sending...",
    HINT_PAUSED = "The game blocked the last mail. Press Send next for each mail.",
    HINT_STOPPING = "Stopping after this mail...",
    HINT_STOPPED = "Stopped. Continue sends to the rest; End gives up on them.",
    SEND_TEXT = "Send",
    SEND_NEXT_TEXT = "Send next",
    CONTINUE_TEXT = "Continue",
    STOP_TEXT = "Stop",
    END_TEXT = "End",
    HINT_NO_RANKS = "Tick at least one rank.",
    HINT_NOBODY = "Nobody in those ranks to mail.",
    HINT_NONE_TICKED = "Tick at least one recipient.",
    HINT_NO_SUBJECT = "Write a subject.",
    HINT_NO_MAILBOX = "Open a mailbox to send.",
    HINT_NO_MONEY = "Not enough money for postage.",
    -- A text-only mail's postage, used away from a mailbox, where the game
    -- doesn't give its price.
    STANDARD_POSTAGE = 30,
    NOT_ENOUGH_COLOR = "ffff4040",
    ONLINE_TEXT = "Online",
    -- "Skip characters not online in the last 30 days".
    ACTIVE_DAYS = 30,
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

-- `copper` as "152g 3s", "12s 60c" or "30c": its non-zero coins, or "0c".
function GuildMail.FormatCopper(copper)
    copper = math.max(0, math.floor(copper or 0))
    local parts = {}
    local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if gold > 0 then
        table.insert(parts, gold .. "g")
    end
    if silver > 0 then
        table.insert(parts, silver .. "s")
    end
    if rest > 0 or #parts == 0 then
        table.insert(parts, rest .. "c")
    end
    return table.concat(parts, " ")
end

-- What sending to `recipients` costs:
--   { mails, players, perMail, total, estimated, affordable }
-- `perMail` is the game's price at a mailbox, or nil away from one, when
-- STANDARD_POSTAGE is used and the cost is `estimated`. `affordable` is
-- true when `money` covers it, or when the money isn't known.
function GuildMail.Cost(recipients, perMail, money)
    local players = {}
    local count = 0
    local index
    for index = 1, #recipients do
        local id = recipients[index].playerId or recipients[index].key
        if id ~= nil and not players[id] then
            players[id] = true
            count = count + 1
        end
    end
    local estimated = type(perMail) ~= "number"
    if estimated then
        perMail = GuildMail.STANDARD_POSTAGE
    end
    local total = perMail * #recipients
    return {
        mails = #recipients,
        players = count,
        perMail = perMail,
        total = total,
        estimated = estimated,
        affordable = type(money) ~= "number" or money >= total,
    }
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
        price = options.price or function()
            return nil
        end,
        money = options.money or function()
            return nil
        end,
        formatMoney = options.formatMoney or function()
            return nil
        end,
        view = options.view,
        testers = options.testers or {},
        ranks = {},
        mode = addon.GuildMailAudience.MAINS,
        skipDiscord = false,
        activeOnly = false,
        subject = "",
        body = "",
        -- Recipients unticked in the list, by character key. Kept for the
        -- session, so a recipient who drops out of the list and comes back
        -- stays unticked; anyone new starts ticked.
        unticked = {},
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

function Mail:ask(callback, ...)
    local ok, value = pcall(callback, ...)
    if ok then
        return value
    end
    return nil
end

-- What sending to `recipients` costs now (GuildMail.Cost), and the
-- officer's money.
function Mail:cost(recipients)
    local price = self.mailboxOpen and self:ask(self.price) or nil
    local money = self:ask(self.money)
    return GuildMail.Cost(recipients, type(price) == "number" and price or nil,
        type(money) == "number" and money or nil), money
end

-- `copper` as the game draws coins, or "12s 60c".
function Mail:coins(copper)
    local text = self:ask(self.formatMoney, copper)
    if type(text) == "string" and text ~= "" then
        return text
    end
    return GuildMail.FormatCopper(copper)
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

-- Whether a send is under way: going, paused or stopped part way.
function Mail:busy()
    return self.sender:IsSending() or self.sender:IsStopped()
end

-- A finished send stays on show until the officer changes something; then
-- the list is worked out afresh. Nothing changes while a send is under
-- way, stopped or not, so continuing it never mails anyone twice.
function Mail:editable()
    if self:busy() then
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

-- "Skip players with a Discord name on file".
function Mail:SetSkipDiscord(skip)
    skip = skip == true
    if skip == self.skipDiscord or not self:editable() then
        return false
    end
    self.skipDiscord = skip
    self:refresh()
    return true
end

-- "Skip characters not online in the last 30 days".
function Mail:SetActiveOnly(active)
    active = active == true
    if active == self.activeOnly or not self:editable() then
        return false
    end
    self.activeOnly = active
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

-- Ticks or unticks the recipient with character `key` in the list.
function Mail:SetRecipient(key, checked)
    local unticked = not checked or nil
    if type(key) ~= "string" or self.unticked[key] == unticked or not self:editable() then
        return false
    end
    self.unticked[key] = unticked
    self:refresh()
    return true
end

-- Whether `recipient` is ticked: not unticked, and their mail fits.
function Mail:isTicked(recipient)
    return not self.unticked[recipient.key] and not (recipient.mail and recipient.mail.warning)
end

-- The recipients in `recipients` that are ticked.
function Mail:ticked(recipients)
    local list = {}
    local index
    for index = 1, #recipients do
        if self:isTicked(recipients[index]) then
            table.insert(list, recipients[index])
        end
    end
    return list
end

function Mail:OnMailboxOpened()
    self.mailboxOpen = true
    self:refresh()
end

-- Closing the mailbox stops sending, as Stop does; the list and progress
-- stay for when it's opened again.
function Mail:OnMailboxClosed()
    self.mailboxOpen = false
    self.confirming = false
    if not self.sender:Stop() then
        self:refresh()
    end
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

-- Who is on the list now, ticked or not, each with their filled-in mail
-- (`mail`, from GuildMailComposer.Compose).
function Mail:Recipients()
    local partition, normalizer = self.context()
    if partition == nil then
        return {}
    end
    local ok, live = pcall(self.live)
    local recipients = addon.GuildMailAudience.Recipients(partition, {
        ranks = self.ranks,
        mode = self.mode,
        live = ok and type(live) == "table" and live or nil,
        selfKey = self.selfKey(),
        skipDiscord = self.skipDiscord,
        activeDays = self.activeOnly and GuildMail.ACTIVE_DAYS or nil,
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
    local index
    for index = 1, #recipients do
        recipients[index].mail = addon.GuildMailComposer.Compose(self.subject, self.body, recipients[index],
            partition, normalizer)
    end
    return recipients
end

-- Why Send can't be pressed now, or nil when it can. `recipients` is the
-- list, ticked or not.
function Mail:hint(recipients)
    if self.sender:IsStopped() then
        return self.mailboxOpen and GuildMail.HINT_STOPPED or GuildMail.HINT_NO_MAILBOX
    end
    if self.sender:IsStopping() then
        return GuildMail.HINT_STOPPING
    end
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
    local ticked = self:ticked(recipients)
    if #ticked == 0 then
        return GuildMail.HINT_NONE_TICKED
    end
    if blank(self.subject) then
        return GuildMail.HINT_NO_SUBJECT
    end
    if not self:cost(ticked).affordable then
        return GuildMail.HINT_NO_MONEY
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
-- While sending is paused (the game blocked a mail), Send
-- next sends the next mail at once: from a click, the game takes it.
-- After Stop, Continue sends to the rows still pending.
function Mail:RequestSend()
    if self.sender:IsPaused() or self.sender:IsStopped() then
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

-- Sends to everyone ticked on the list, one mail at a time.
function Mail:Confirm()
    if not self.confirming then
        return false
    end
    self.confirming = false
    if not self:CanSend() then
        self:refresh()
        return false
    end
    local recipients = self:ticked(self:Recipients())
    local mails = {}
    local index
    for index = 1, #recipients do
        local mail = recipients[index].mail
        mails[index] = { to = recipients[index].name, subject = mail.subject, body = mail.body }
    end
    self.batch = recipients
    self.batchPerMail = self:cost(recipients).perMail
    return self.sender:Start(mails)
end

-- Stops sending after the mail in flight. Returns false when nothing is
-- being sent.
function Mail:Stop()
    return self.sender:Stop()
end

-- After Stop, gives up on the rows still pending: the send is finished.
function Mail:End()
    return self.sender:End()
end

-- MAIL_SEND_SUCCESS and MAIL_FAILED, passed on to the sender.
function Mail:OnSent()
    return self.sender:OnSent()
end

function Mail:OnFailed(reason)
    return self.sender:OnFailed(reason)
end

-- The game showed an error: it may be why a mail failed.
function Mail:OnError(message)
    return self.sender:OnError(message)
end

-- The game blocked the add-on's SendMail: wait for Send next.
function Mail:OnBlocked()
    return self.sender:OnBlocked()
end

function Mail:IsSending()
    return self.sender:IsSending()
end

-- "Sent 3 of 12, 1 failed · Postage spent: 90c" while sending; once done,
-- the summary "Sent 40 · Failed 2 · Postage spent: 12s".
function Mail:progressText()
    if self.batch == nil then
        return nil
    end
    local progress = self.sender:Progress()
    local postage = " · Postage spent: " .. self:coins(progress.sent * (self.batchPerMail or 0))
    if progress.state == addon.GuildMailSender.DONE then
        return "Sent " .. progress.sent .. " · Failed " .. progress.failed .. postage
    end
    local text = "Sent " .. progress.sent .. " of " .. progress.total
    if progress.failed > 0 then
        text = text .. ", " .. progress.failed .. " failed"
    end
    return text .. postage
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
--   skipDiscord, activeOnly   the two skip check boxes
--   subject, body
--   recipients   { key, name, playerName, rank, rankName, lastSeen,
--                checked, warning, status, reason }; `warning` says why
--                the filled-in mail is too long; status is nil
--                until a send starts, then "pending", "sent" or "failed"
--   countText    "12 mails", or "10 of 12 mails" with some unticked
--   costText     "42 mails to 38 players · Estimated cost: 12s 60c (30c
--                each)", in red when the officer can't afford it
--   moneyText    "You have 152g 3s", or nil when the money isn't known
--   affordable   whether the officer's money covers the cost
--   canSend      whether Send can be pressed
--   sendText     "Send", "Send next" while paused, "Continue" after Stop
--   stopText     "Stop" while sending, "End" after Stop, else nil
--   canStop      whether that button can be pressed
--   hint         why Send can't be pressed, or what's happening, or nil
--   preview      { to, subject, body }: the mail as the first ticked
--                recipient gets it, or nil when nobody is ticked
--   confirming   whether the confirmation is up, with confirmText
--   progressText "Sent 3 of 12", or nil before a send
--   sending      whether a send is under way (going, paused or stopped),
--                which locks everything but Send and Stop
function Mail:Model()
    local partition = self.context()
    local ranks = self:rankList(partition)
    local rankNames = {}
    local index
    for index = 1, #ranks do
        rankNames[ranks[index].index] = ranks[index].name
    end
    local recipients = self.batch or self:Recipients()
    local ticked = self.batch or self:ticked(recipients)
    local rows = {}
    for index = 1, #recipients do
        local status, reason
        if self.batch ~= nil then
            status, reason = self.sender:Status(index)
        end
        rows[index] = {
            key = recipients[index].key,
            name = recipients[index].name,
            playerName = recipients[index].playerName,
            lastSeen = lastSeen(recipients[index]),
            rank = recipients[index].rank,
            rankName = rankNames[recipients[index].rank] or ("Rank " .. (recipients[index].rank + 1)),
            checked = self.batch ~= nil or self:isTicked(recipients[index]),
            warning = recipients[index].mail and recipients[index].mail.warning,
            status = status,
            reason = reason,
        }
    end
    local hint = self:hint(recipients)
    local officer = self:IsOfficer()
    local cost, money = self:cost(ticked)
    local costText = plural(cost.mails, "mail", "mails") .. " to " .. plural(cost.players, "player", "players") ..
        " · Estimated cost: " .. self:coins(cost.total) .. " (" .. self:coins(cost.perMail) .. " each)"
    if not cost.affordable then
        costText = "|c" .. GuildMail.NOT_ENOUGH_COLOR .. costText .. "|r"
    end
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
        skipDiscord = self.skipDiscord,
        activeOnly = self.activeOnly,
        subject = self.subject,
        body = self.body,
        recipients = rows,
        countText = #ticked == #rows and plural(#rows, "mail", "mails")
            or (#ticked .. " of " .. plural(#rows, "mail", "mails")),
        costText = costText,
        moneyText = type(money) == "number" and ("You have " .. self:coins(money)) or nil,
        affordable = cost.affordable,
        canSend = officer and ((hint == nil and self.batch == nil)
            or ((self.sender:IsPaused() or self.sender:IsStopped()) and self.mailboxOpen)),
        sendText = (self.sender:IsStopped() and GuildMail.CONTINUE_TEXT)
            or (self.sender:IsPaused() and GuildMail.SEND_NEXT_TEXT) or GuildMail.SEND_TEXT,
        stopText = (self.sender:IsStopped() and GuildMail.END_TEXT)
            or (self.sender:IsSending() and GuildMail.STOP_TEXT) or nil,
        canStop = self.sender:IsStopped() or (self.sender:IsSending() and not self.sender:IsStopping()),
        hint = hint,
        confirming = self.confirming,
        confirmText = "Send " .. plural(#ticked, "mail", "mails") .. " for " .. self:coins(cost.total) .. " postage?",
        preview = ticked[1] and ticked[1].mail and {
            to = ticked[1].name, subject = ticked[1].mail.subject, body = ticked[1].mail.body,
        } or nil,
        progressText = self:progressText(),
        sending = self:busy(),
    }
end
