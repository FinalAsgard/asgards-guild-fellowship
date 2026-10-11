local _, addon = ...

-- Guild Recruit: prompts a member who can invite to the guild, and who
-- turned advertise prompts on, to post their ad in the current zone's General
-- channel, or in Trade, when the guild hasn't advertised there lately. A
-- channel that comes due while the user stays put is prompted then too. A press of Post
-- sends it. It wires RecruitLedger (when each channel was last advertised in)
-- and RecruitPolicy (which channels are due) to the game through the
-- functions it's given, so it never touches the game itself. Nothing is ever
-- posted without the user pressing Post.
--
-- Each character has its own answer to "Help with guild recruitment?":
-- undecided (nil), Yes (true) or No (false), and only Yes allows prompts.
-- Once per login, when the guild roster has loaded, the character's invite
-- permission is checked: without it the answer goes back to undecided;
-- with it, an undecided character is asked. Within a session, permission is
-- checked live, so losing it stops prompts at once, but only the login check
-- resets the answer.
--
-- Add-on users coordinate: after the user's ad posts, an "advertised" message
-- tells the guild's other add-on users, who record the time for that channel
-- (in any zone) and close their own prompt for it. A prompt waits a short
-- random moment before showing, so two users rarely get the same one at the
-- same instant. A channel whose time is unknown (no time, or a stale one)
-- is asked about with "ask-channel"; add-ons holding a fresh time answer
-- with "channel-time" after a random moment, unless someone else answered
-- first with the same time or a newer one. When nobody answers, the channel
-- is taken as not advertised in. Without add-on messaging, it simply works
-- uncoordinated: an ask nobody can hear counts as unanswered at once.
--
-- Officers write the guild ad and switch it on or off (RecruitConfig). A
-- change is broadcast as "config", and every add-on asks for the newest
-- settings at login with "ask-config"; officers' add-ons answer. Settings
-- are taken only from officers. Each post picks at random between the
-- usable ads: the guild ad, when it's on and the user posts it, and the
-- user's own.
local GuildRecruit = {
    -- The "advertised" message: { v = PROTOCOL, t = TYPE_ADVERTISED, k = the
    -- channel key, n = the channel's display name, a = when it was posted
    -- (server time) }. The poster is whoever the game says sent it.
    PROTOCOL = 1,
    TYPE_ADVERTISED = "advertised",
    -- { v, t = TYPE_ASK, k = the channel key }: who has a fresh time for it?
    TYPE_ASK = "ask-channel",
    -- { v, t = TYPE_CHANNEL_TIME, k = the channel key, a = the newest time
    -- the sender knows }.
    TYPE_CHANNEL_TIME = "channel-time",
    -- How long an ask waits for answers before the channel counts as due.
    ASK_WAIT_SECONDS = 8,
    -- { v, t = TYPE_CONFIG, s = { [setting] = { value, at, by } } }: the
    -- officer settings that have been changed (see RecruitConfig).
    TYPE_CONFIG = "config",
    -- { v, t = TYPE_ASK_CONFIG }: who has the officer settings?
    TYPE_ASK_CONFIG = "ask-config",
    -- An answer waits a random whole number of seconds in this range, so
    -- the first answer heard can stop the rest.
    ANSWER_DELAY_MIN = 1,
    ANSWER_DELAY_MAX = 5,
    -- A prompt shows a random whole number of seconds in this range after
    -- its channel comes due.
    SHOW_DELAY_MIN = 3,
    SHOW_DELAY_MAX = 20,
    QUESTION = "Help with guild recruitment?",
    -- How long Not now hides a channel's prompt.
    SNOOZE_SECONDS = 10 * 60,
}
addon.GuildRecruit = GuildRecruit

local Recruit = {}
Recruit.__index = Recruit

-- options:
--   partition   function() -> the current guild's partition, or nil
--   selfKey     function() -> the logged-in character's key, or nil
--   store       function() -> the FellowshipStore, or nil
--   now         function() -> server time in seconds
--   canInvite   function() -> true when the character can invite to the
--               guild
--   location    function() -> { key, name, general, trade }: the zone's
--               key and name, and the numbers of its General channel and
--               of Trade (nil where the user isn't in them); nil when the
--               zone is unknown
--   after       function(seconds, callback) -> false when there's no timer
--   inInstance  function() -> true in an instance, battleground or keystone
--               run, where prompts are held. Optional.
--   random      function(low, high) -> a whole number. Optional.
--   showDelay   function() -> seconds a newly due prompt waits before
--               showing. Optional; a random 3 to 20 otherwise.
--   announce    function(message) -> sends an "advertised" message to the
--               guild's add-on users. Optional.
--   isOwn       function(sender) -> true when a message's sender is one of
--               the user's own characters. Optional.
--   keyOf       function(sender) -> the sender's character key, or nil.
--               Optional; without it, heard ad counts aren't kept.
--   isOwnKey    function(key) -> true for one of the user's own characters.
--               Optional.
--   askWait     function() -> seconds an ask waits for answers. Optional;
--               ASK_WAIT_SECONDS otherwise.
--   isOfficer   function(key) -> true when a character is an officer.
--               Optional; nobody is without it.
--   senderIsOfficer function(sender) -> true when a message's sender is an
--               officer. Optional; nobody is without it.
--   send        function(text, channelNumber) -> true when posted
--   rosterLoaded function() -> true once the guild roster has loaded
--   view        { Show = function(view, prompts, handlers),
--               Ask = function(view, question, handlers) }: draws the
--               prompts (handlers.post(key), handlers.notNow(key) and
--               handlers.offHere(key) answer their buttons) and the login
--               question, or hides it when `question` is nil
--               (handlers.yes(), handlers.no() and handlers.close())
function GuildRecruit.Create(options)
    local recruit = setmetatable({
        partition = options.partition,
        selfKey = options.selfKey,
        store = options.store,
        now = options.now,
        canInvite = options.canInvite,
        location = options.location,
        send = options.send,
        after = options.after or function()
            return false
        end,
        rosterLoaded = options.rosterLoaded,
        inInstance = options.inInstance or function()
            return false
        end,
        random = options.random or function(low)
            return low
        end,
        showDelay = options.showDelay,
        announce = options.announce or function()
            return false
        end,
        isOwn = options.isOwn or function()
            return false
        end,
        keyOf = options.keyOf or function()
            return nil
        end,
        isOwnKey = options.isOwnKey or function()
            return false
        end,
        askWait = options.askWait,
        isOfficer = options.isOfficer or function()
            return false
        end,
        senderIsOfficer = options.senderIsOfficer or function()
            return false
        end,
        -- True while this add-on's answer to an ask-config waits, and once
        -- this session's ask-config was sent.
        answeringConfig = false,
        askedConfig = false,
        -- When each channel that's due but not yet shown will show.
        showAt = {},
        -- This session's due marks (see RecruitLedger), the channels being
        -- asked about, and the answers waiting to be sent (key -> time).
        dueMarks = {},
        askingAbout = {},
        answering = {},
        -- True during combat or a boss encounter.
        inCombat = false,
        -- This session's Not now (channel key -> when it ends) and Off here
        -- (zone key -> true). Neither is saved.
        snoozes = {},
        muted = {},
        view = options.view,
        -- True once this login's permission check has run.
        loginChecked = false,
        -- True while the login question is waiting for an answer.
        asking = false,
        -- The prompts on screen, in order.
        prompts = {},
        -- When the pending timer for the next channel to come due fires.
        wakeAt = nil,
    }, Recruit)
    recruit.policy = addon.RecruitPolicy.Create({
        canInvite = function()
            return recruit:CanInvite()
        end,
        optedIn = function()
            return recruit:IsOptedIn()
        end,
        hasAd = function()
            return recruit:HasAd()
        end,
        busy = function()
            return recruit:IsBusy()
        end,
        snoozedUntil = function(key)
            return recruit.snoozes[key]
        end,
        muted = function(zoneKey)
            return recruit.muted[zoneKey] == true
        end,
        paused = function()
            return recruit:Config():Get("paused") == true
        end,
    })
    return recruit
end

-- True when the logged-in character can invite to the guild.
function Recruit:CanInvite()
    local ok, can = pcall(self.canInvite)
    return ok and can == true
end

-- True while prompts are held: combat, a boss encounter, or an instance,
-- battleground or keystone run.
function Recruit:IsBusy()
    if self.inCombat then
        return true
    end
    local ok, inside = pcall(self.inInstance)
    return ok and inside == true
end

-- The user entered (true) or left (false) combat or a boss encounter.
-- Prompts wait until it's over; any still due appear then.
function Recruit:OnCombatChanged(inCombat)
    self.inCombat = inCombat == true
    self:Refresh()
end

-- True when the logged-in character turned advertise prompts on.
function Recruit:IsOptedIn()
    local store, selfKey = self.store(), self.selfKey()
    return store ~= nil and selfKey ~= nil and store:RecruitOptedIn(selfKey)
end

-- The officer settings for the current guild, saved with its partition.
function Recruit:Config()
    local partition = self.partition()
    return addon.RecruitConfig.Create(partition and partition:GetRecruitConfig(), {
        isOfficer = self.isOfficer,
    })
end

-- One usable ad, exactly as written, picked with `random`; nil when none is
-- usable.
function Recruit:pickAd(random)
    local store = self.store()
    local config = self:Config()
    return addon.RecruitConfig.PickAd({
        officerAd = config:Get("guildAd"),
        officerOn = config:Get("guildAdOn"),
        useOfficer = store == nil or store:RecruitUseOfficerAd(),
        ownAd = store and store:RecruitAd() or "",
        random = random,
    })
end

-- The ad to post: picked at random between the usable ones, or nil when
-- there's none.
function Recruit:Ad()
    return self:pickAd(self.random)
end

-- True when there's an ad to post.
function Recruit:HasAd()
    return self:pickAd(function(low)
        return low
    end) ~= nil
end

-- True when the logged-in character is an officer.
function Recruit:IsOfficer()
    local selfKey = self.selfKey()
    local ok, officer = pcall(self.isOfficer, selfKey)
    return selfKey ~= nil and ok and officer == true
end

-- An officer changed setting `name` (see RecruitConfig) to `value`: saves it
-- stamped with now and the officer's character, tells the other add-on
-- users, and redraws. Returns true, or nil and a reason a player can read.
function Recruit:SetOfficerSetting(name, value)
    local selfKey, now = self.selfKey(), self.now()
    if not self:IsOfficer() then
        return nil, "only officers can change it"
    end
    if self.partition() == nil or type(now) ~= "number" then
        return nil, "saved data is unavailable"
    end
    local entry = self:Config():Set(name, value, now, selfKey)
    if entry == nil then
        return nil, "it can't be set to that"
    end
    self:sendConfig()
    self:Refresh()
    return true
end

-- Sends the officer settings that have been changed, if any.
function Recruit:sendConfig()
    local changes = self:Config():Changes()
    if changes ~= nil then
        pcall(self.announce, { v = GuildRecruit.PROTOCOL, t = GuildRecruit.TYPE_CONFIG, s = changes })
    end
end

-- The ledger of ad times for the current guild, saved with its partition.
function Recruit:Ledger()
    local partition = self.partition()
    local config = self:Config()
    return addon.RecruitLedger.Create(partition and partition:GetRecruitLedger(), function(key)
        return GuildRecruit.GapOf(key, config)
    end, self.dueMarks)
end

-- The current location, or nil.
function Recruit:Location()
    local ok, location = pcall(self.location)
    if ok and type(location) == "table" then
        return location
    end
    return nil
end

-- The gap in seconds for a channel key, as the guild's officer settings
-- (a RecruitConfig) have it: how long after an ad in a zone's General, or
-- in Trade (one channel in every city), the next one is due.
function GuildRecruit.GapOf(key, config)
    if key == addon.RecruitLedger.TRADE_KEY then
        return config:Get("tradeGapMinutes") * 60
    end
    return config:Get("generalGapMinutes") * 60
end

-- The question a prompt asks.
function GuildRecruit.PromptText(prompt)
    if prompt.channel == addon.RecruitPolicy.TRADE then
        return "Advertise in Trade?"
    end
    return "Advertise in " .. tostring(prompt.zoneName or "this zone") .. " General?"
end

-- Sets a timer for when the next channel here comes due, unless one is
-- already set for then or sooner.
function Recruit:wakeIn(seconds, now)
    if seconds == nil then
        return
    end
    local at = now + seconds
    if self.wakeAt ~= nil and self.wakeAt > now and self.wakeAt <= at then
        return
    end
    if self.after(seconds, function()
        if self.wakeAt == at then
            self.wakeAt = nil
        end
        self:Refresh()
    end) then
        self.wakeAt = at
    end
end

-- Seconds an ask waits for answers.
function Recruit:AskWait()
    if self.askWait == nil then
        return GuildRecruit.ASK_WAIT_SECONDS
    end
    local ok, wait = pcall(self.askWait)
    if not ok or type(wait) ~= "number" or wait < 0 then
        return GuildRecruit.ASK_WAIT_SECONDS
    end
    return wait
end

-- Asks the other add-on users about each of `channels` not already being
-- asked about. When the wait ends with no fresh time heard, the channel is
-- due. An ask that can't be sent, or can't be waited for, ends at once.
function Recruit:ask(channels, ledger)
    local index
    for index = 1, #channels do
        local key = channels[index].key
        if not self.askingAbout[key] then
            local wait = self:AskWait()
            local okSent, sent = pcall(self.announce, { v = GuildRecruit.PROTOCOL, t = GuildRecruit.TYPE_ASK, k = key })
            if okSent and sent == true and wait > 0 and self.after(wait, function()
                self.askingAbout[key] = nil
                -- An answer heard meanwhile made it fresh; once that goes
                -- stale it's asked about again, so it isn't marked due.
                local ledger = self:Ledger()
                local current = self.now()
                if type(current) ~= "number" or ledger:State(key, current) ~= addon.RecruitLedger.FRESH then
                    ledger:MarkDue(key)
                end
                self:Refresh()
            end) then
                self.askingAbout[key] = true
            else
                ledger:MarkDue(key)
            end
        end
    end
end

-- Seconds a newly due prompt waits before showing.
function Recruit:ShowDelay()
    local ok, delay
    if self.showDelay ~= nil then
        ok, delay = pcall(self.showDelay)
    else
        ok, delay = pcall(self.random, GuildRecruit.SHOW_DELAY_MIN, GuildRecruit.SHOW_DELAY_MAX)
    end
    if not ok or type(delay) ~= "number" or delay < 0 then
        return GuildRecruit.SHOW_DELAY_MIN
    end
    return delay
end

-- The due prompts that have waited out their show delay, with their text.
-- A channel newly due starts its delay now; one no longer due forgets it,
-- so a channel advertised in while it waits never shows. Without a timer
-- to show it later, a prompt shows at once.
function Recruit:visible(due, now)
    local shown = {}
    local stillDue = {}
    local index
    for index = 1, #due do
        local prompt = due[index]
        stillDue[prompt.key] = true
        if self.showAt[prompt.key] == nil then
            local delay = self:ShowDelay()
            if delay > 0 and not self.after(delay, function()
                self:Refresh()
            end) then
                delay = 0
            end
            self.showAt[prompt.key] = now + delay
        end
        if type(now) == "number" and self.showAt[prompt.key] <= now then
            prompt.text = GuildRecruit.PromptText(prompt)
            table.insert(shown, prompt)
        end
    end
    local key
    local forgotten = {}
    for key in pairs(self.showAt) do
        if not stillDue[key] then
            table.insert(forgotten, key)
        end
    end
    for index = 1, #forgotten do
        self.showAt[forgotten[index]] = nil
    end
    return shown
end

-- Works out the prompts due now and draws them: new ones appear, and ones
-- no longer due (advertised, left behind, or not allowed any more) close.
-- Called whenever anything they depend on may have changed.
function Recruit:Refresh()
    local now = self.now()
    local due = {}
    -- Nothing is prompted before this login's check, once the roster has
    -- loaded; saved guild data is only opened then.
    -- The first time this session the user recruits (can invite, and opted
    -- in), the officers' add-ons are asked for the newest settings, which
    -- may hold the only ad the user has.
    if self.loginChecked and not self.askedConfig and self:CanInvite() and self:IsOptedIn() then
        self.askedConfig = true
        pcall(self.announce, { v = GuildRecruit.PROTOCOL, t = GuildRecruit.TYPE_ASK_CONFIG })
    end
    if type(now) == "number" and self.loginChecked and self.policy:Allowed() then
        local ledger = self:Ledger()
        local location = self:Location()
        ledger:Prune(now)
        self:ask(self.policy:Unknown(location, ledger, now), ledger)
        due = self.policy:Due(location, ledger, now)
        self:wakeIn(self.policy:NextDue(location, ledger, now), now)
    end
    self.prompts = self:visible(due, now)
    -- An answer given some other way (the settings) settles the question.
    if self.asking and self:Answer() ~= nil then
        self.asking = false
        self:drawQuestion()
    end
    self:draw()
end

-- The logged-in character's saved answer: true, false, or nil (undecided,
-- or no saved data).
function Recruit:Answer()
    local store, selfKey = self.store(), self.selfKey()
    if store == nil or selfKey == nil then
        return nil
    end
    return store:RecruitOptIn(selfKey)
end

-- Called on every roster update. The first one with the roster loaded and
-- the character known runs this login's permission check; later calls only
-- refresh the prompts.
function Recruit:OnRosterUpdate()
    if not self.loginChecked then
        local ok, loaded = pcall(self.rosterLoaded)
        local store, selfKey = self.store(), self.selfKey()
        if ok and loaded == true and store ~= nil and selfKey ~= nil then
            self.loginChecked = true
            if not self:CanInvite() then
                if store:RecruitOptIn(selfKey) ~= nil then
                    store:SetRecruitOptIn(selfKey, nil)
                end
            elseif store:RecruitOptIn(selfKey) == nil then
                self.asking = true
                self:drawQuestion()
            end
        end
    end
    self:Refresh()
end

-- The user answered the login question: Yes (true) or No (false). Saves
-- it for the logged-in character and closes the question.
function Recruit:AnswerQuestion(answer)
    local store, selfKey = self.store(), self.selfKey()
    if store ~= nil and selfKey ~= nil then
        store:SetRecruitOptIn(selfKey, answer == true)
    end
    self.asking = false
    self:drawQuestion()
    self:Refresh()
end

-- The user closed the question without answering: it stays undecided, so
-- it's asked again at the next login.
function Recruit:CloseQuestion()
    self.asking = false
    self:drawQuestion()
end

-- True while the login question is on screen.
function Recruit:IsAsking()
    return self.asking
end

function Recruit:drawQuestion()
    if self.view == nil or type(self.view.Ask) ~= "function" then
        return
    end
    pcall(self.view.Ask, self.view, self.asking and GuildRecruit.QUESTION or nil, {
        yes = function()
            self:AnswerQuestion(true)
        end,
        no = function()
            self:AnswerQuestion(false)
        end,
        close = function()
            self:CloseQuestion()
        end,
    })
end

function Recruit:draw()
    if self.view == nil then
        return
    end
    pcall(self.view.Show, self.view, self.prompts, {
        post = function(key)
            self:Post(key)
        end,
        notNow = function(key)
            self:NotNow(key)
        end,
        offHere = function(key)
            self:OffHere(key)
        end,
    })
end

-- The prompt on screen for `key`, or nil.
function Recruit:Prompt(key)
    local index
    for index = 1, #self.prompts do
        if self.prompts[index].key == key then
            return self.prompts[index]
        end
    end
    return nil
end

-- The user pressed Post on the prompt for `key`: sends the ad to that
-- channel. Only a successful send counts as an ad and closes the prompt; a
-- failed one records nothing and leaves it open. Returns the text sent, or
-- nil.
function Recruit:Post(key)
    local prompt = self:Prompt(key)
    local ad = self:Ad()
    local now = self.now()
    if prompt == nil or ad == nil or type(now) ~= "number" or not self.policy:Allowed() then
        self:Refresh()
        return nil
    end
    -- The channel is looked up again, in case the user moved since the
    -- prompt appeared.
    local location = self:Location()
    local channelNumber = location and location[prompt.channel]
    if location == nil or location.key ~= prompt.zoneKey or type(channelNumber) ~= "number" then
        self:Refresh()
        return nil
    end
    local ok, sent = pcall(self.send, ad, channelNumber)
    if not ok or sent ~= true then
        return nil
    end
    self:Ledger():Record(key, now)
    -- The user's own record counts the ad, and goes with the message.
    local store = self.store()
    local record = store and store:RecruitOwnStats()
    local report = record and addon.RecruitStats.AddOwn(record, now)
    pcall(self.announce, {
        v = GuildRecruit.PROTOCOL,
        t = GuildRecruit.TYPE_ADVERTISED,
        k = key,
        n = prompt.channel == addon.RecruitPolicy.TRADE and "Trade" or ((prompt.zoneName or "") .. " General"),
        a = now,
        r = report,
    })
    self:Refresh()
    return ad
end

-- True for a channel key this add-on could have written: a zone's General
-- or Trade.
local function isChannelKey(key)
    return key == addon.RecruitLedger.TRADE_KEY
        or (type(key) == "string" and string.sub(key, 1, 8) == "general:" and string.len(key) > 8)
end

-- True for a message of `kind` in this protocol about a channel key, with a
-- time when `timed`.
local function isMessage(message, kind, timed)
    if type(message) ~= "table" or message.v ~= GuildRecruit.PROTOCOL or message.t ~= kind
        or not isChannelKey(message.k)
    then
        return false
    end
    return not timed or (type(message.a) == "number" and message.a == message.a)
end

-- True when `sender` is someone else's add-on; a sender that can't be
-- placed counts as the user's own.
function Recruit:fromOthers(sender)
    if type(sender) ~= "string" then
        return false
    end
    local ok, own = pcall(self.isOwn, sender)
    return ok and own == false
end

-- Records another add-on user's time for `key`. Refreshes when it was
-- newer, so a prompt for a channel that's now fresh closes. Returns true
-- when the time was kept.
function Recruit:hear(key, at)
    if self.partition() == nil then
        return false
    end
    local recorded = self:Ledger():Record(key, at)
    if recorded then
        self:Refresh()
    end
    return recorded
end

-- Another add-on user's "advertised" message, from `sender` (a name as the
-- game reports it). Records the time for that channel, in any zone, and
-- closes the user's prompt for it if it's now fresh. Messages from the
-- user's own characters and malformed ones are ignored. Returns true when
-- the time was recorded.
function Recruit:OnAdvertised(message, sender)
    if not isMessage(message, GuildRecruit.TYPE_ADVERTISED, true)
        or (message.n ~= nil and type(message.n) ~= "string") or not self:fromOthers(sender)
    then
        return false
    end
    -- The poster's ad count, kept under their character.
    local okKey, senderKey = pcall(self.keyOf, sender)
    local partition = self.partition()
    if okKey and type(senderKey) == "string" and partition ~= nil and message.r ~= nil then
        addon.RecruitStats.Create(partition:GetRecruitStats()):File(senderKey, message.r)
    end
    return self:hear(message.k, message.a)
end

-- Another add-on user's "ask-channel": when this add-on has a fresh time
-- for the channel, it answers after a random short wait, unless an answer
-- with the same time or a newer one is heard first. Returns true when an
-- answer was scheduled.
function Recruit:OnAsk(message, sender)
    if not isMessage(message, GuildRecruit.TYPE_ASK, false) or not self:fromOthers(sender)
        or self.partition() == nil or self.answering[message.k] ~= nil
    then
        return false
    end
    local key = message.k
    local now = self.now()
    local ledger = self:Ledger()
    if type(now) ~= "number" or ledger:State(key, now) ~= addon.RecruitLedger.FRESH then
        return false
    end
    local function answer()
        local time = self.answering[key]
        self.answering[key] = nil
        local current = self.now()
        if time ~= nil and type(current) == "number"
            and self:Ledger():State(key, current) == addon.RecruitLedger.FRESH
        then
            pcall(self.announce, {
                v = GuildRecruit.PROTOCOL, t = GuildRecruit.TYPE_CHANNEL_TIME, k = key, a = self:Ledger():Time(key),
            })
        end
    end
    self.answering[key] = ledger:Time(key)
    local okDelay, delay = pcall(self.random, GuildRecruit.ANSWER_DELAY_MIN, GuildRecruit.ANSWER_DELAY_MAX)
    if not okDelay or type(delay) ~= "number" or delay < 0 then
        delay = GuildRecruit.ANSWER_DELAY_MIN
    end
    if not self.after(delay, answer) then
        answer()
    end
    return true
end

-- Another add-on user's "channel-time": recorded like an "advertised"
-- message, and it stops this add-on's own answer for that channel when it's
-- as new or newer. Returns true when the time was recorded.
function Recruit:OnChannelTime(message, sender)
    if not isMessage(message, GuildRecruit.TYPE_CHANNEL_TIME, true) or not self:fromOthers(sender) then
        return false
    end
    local pending = self.answering[message.k]
    if pending ~= nil and message.a >= pending then
        self.answering[message.k] = nil
    end
    return self:hear(message.k, message.a)
end

-- The user pressed Not now on the prompt for `key`: hides that channel's
-- prompt for 10 minutes. After that it appears again if still due.
function Recruit:NotNow(key)
    local now = self.now()
    if self:Prompt(key) ~= nil and type(now) == "number" then
        self.snoozes[key] = now + GuildRecruit.SNOOZE_SECONDS
    end
    self:Refresh()
end

-- The user pressed Off here on the prompt for `key`: no more prompts in that
-- prompt's zone (its General, and Trade while there) until logout or
-- reload.
function Recruit:OffHere(key)
    local prompt = self:Prompt(key)
    if prompt ~= nil and prompt.zoneKey ~= nil then
        self.muted[prompt.zoneKey] = true
    end
    self:Refresh()
end

-- A "config" message: applied setting by setting, newest wins, when both
-- the sender and each change's author are officers. Hearing one that holds
-- everything this add-on knows stops its own answer to an ask-config.
-- Returns true when any setting changed.
function Recruit:OnConfig(message, sender)
    if type(message) ~= "table" or message.v ~= GuildRecruit.PROTOCOL or message.t ~= GuildRecruit.TYPE_CONFIG
        or type(message.s) ~= "table" or not self:fromOthers(sender) or self.partition() == nil
    then
        return false
    end
    local ok, officer = pcall(self.senderIsOfficer, sender)
    if not ok or officer ~= true then
        return false
    end
    local config = self:Config()
    if self.answeringConfig and config:CoveredBy(message.s) then
        self.answeringConfig = false
    end
    local changed = false
    local name
    for name in pairs(addon.RecruitConfig.SETTINGS) do
        if config:Apply(name, message.s[name]) then
            changed = true
        end
    end
    if changed then
        self:Refresh()
    end
    return changed
end

-- Another add-on user's "ask-config": an officer's add-on that has settings
-- answers with them after a random short wait, unless a config holding them
-- all is heard first. Returns true when an answer was scheduled.
function Recruit:OnAskConfig(message, sender)
    if type(message) ~= "table" or message.v ~= GuildRecruit.PROTOCOL or message.t ~= GuildRecruit.TYPE_ASK_CONFIG
        or not self:fromOthers(sender) or self.answeringConfig or not self:IsOfficer()
        or self.partition() == nil or self:Config():Changes() == nil
    then
        return false
    end
    self.answeringConfig = true
    local function answer()
        if self.answeringConfig then
            self.answeringConfig = false
            self:sendConfig()
        end
    end
    local okDelay, delay = pcall(self.random, GuildRecruit.ANSWER_DELAY_MIN, GuildRecruit.ANSWER_DELAY_MAX)
    if not okDelay or type(delay) ~= "number" or delay < 0 then
        delay = GuildRecruit.ANSWER_DELAY_MIN
    end
    if not self.after(delay, answer) then
        answer()
    end
    return true
end

-- The player panel's ad count line for a player with the characters `keys`:
-- the user's own record for the user's own player, else the highest heard
-- among their characters. Nil when there's none.
function Recruit:StatsLine(keys)
    local now = self.now()
    local index
    for index = 1, #(keys or {}) do
        local ok, own = pcall(self.isOwnKey, keys[index])
        if ok and own == true then
            local store = self.store()
            local record = store and store:RecruitOwnStats()
            if record == nil or record.n == 0 then
                return nil
            end
            return addon.RecruitStats.Line(record, now)
        end
    end
    local partition = self.partition()
    if partition == nil then
        return nil
    end
    return addon.RecruitStats.Line(addon.RecruitStats.Create(partition:GetRecruitStats()):Best(keys), now)
end

-- Every Guild Recruit message type, for routing.
GuildRecruit.TYPES = {
    [GuildRecruit.TYPE_ADVERTISED] = "OnAdvertised",
    [GuildRecruit.TYPE_ASK] = "OnAsk",
    [GuildRecruit.TYPE_CHANNEL_TIME] = "OnChannelTime",
    [GuildRecruit.TYPE_CONFIG] = "OnConfig",
    [GuildRecruit.TYPE_ASK_CONFIG] = "OnAskConfig",
}

-- Hands a received Guild Recruit message to its handler. Returns false for
-- any other message.
function Recruit:OnMessage(message, sender)
    local handler = type(message) == "table" and GuildRecruit.TYPES[message.t] or nil
    if handler == nil then
        return false
    end
    return self[handler](self, message, sender)
end
