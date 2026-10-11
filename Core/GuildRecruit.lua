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
local GuildRecruit = {
    QUESTION = "Help with guild recruitment?",
    -- How long after an ad in a zone's General channel the next one is due.
    GENERAL_GAP_SECONDS = 60 * 60,
    -- The same for Trade, one channel shared by every city.
    TRADE_GAP_SECONDS = 20 * 60,
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
--   send        function(text, channelNumber) -> true when posted
--   rosterLoaded function() -> true once the guild roster has loaded
--   view        { Show = function(view, prompts, handlers),
--               Ask = function(view, question, handlers) }: draws the
--               prompts (handlers.post(key) answers Post) and the login
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
            return recruit:Ad() ~= nil
        end,
    })
    return recruit
end

-- True when the logged-in character can invite to the guild.
function Recruit:CanInvite()
    local ok, can = pcall(self.canInvite)
    return ok and can == true
end

-- True when the logged-in character turned advertise prompts on.
function Recruit:IsOptedIn()
    local store, selfKey = self.store(), self.selfKey()
    return store ~= nil and selfKey ~= nil and store:RecruitOptedIn(selfKey)
end

-- The ad to post, exactly as the user wrote it, or nil when there's none.
function Recruit:Ad()
    local store = self.store()
    local ad = store and store:RecruitAd() or ""
    if string.find(ad, "%S") == nil then
        return nil
    end
    return ad
end

-- The ledger of ad times for the current guild, saved with its partition.
function Recruit:Ledger()
    local partition = self.partition()
    return addon.RecruitLedger.Create(partition and partition:GetRecruitLedger(), GuildRecruit.GapOf)
end

-- The current location, or nil.
function Recruit:Location()
    local ok, location = pcall(self.location)
    if ok and type(location) == "table" then
        return location
    end
    return nil
end

-- The gap in seconds for a channel key.
function GuildRecruit.GapOf(key)
    if key == addon.RecruitLedger.TRADE_KEY then
        return GuildRecruit.TRADE_GAP_SECONDS
    end
    return GuildRecruit.GENERAL_GAP_SECONDS
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

-- Works out the prompts due now and draws them: new ones appear, and ones
-- no longer due (advertised, left behind, or not allowed any more) close.
-- Called whenever anything they depend on may have changed.
function Recruit:Refresh()
    local now = self.now()
    local due = {}
    -- Saved guild data is only opened for a user who may be prompted.
    if type(now) == "number" and self.policy:Allowed() then
        local ledger = self:Ledger()
        local location = self:Location()
        ledger:Prune(now)
        due = self.policy:Due(location, ledger, now)
        self:wakeIn(self.policy:NextDue(location, ledger, now), now)
    end
    local index
    for index = 1, #due do
        due[index].text = GuildRecruit.PromptText(due[index])
    end
    self.prompts = due
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
    self:Refresh()
    return ad
end
