local _, addon = ...

-- Guild Recruit: prompts a member who can invite to the guild, and who
-- turned advertise prompts on, to post their ad in the current zone's General
-- channel when the guild hasn't advertised there lately. A press of Post
-- sends it. It wires RecruitLedger (when each channel was last advertised in)
-- and RecruitPolicy (which channels are due) to the game through the
-- functions it's given, so it never touches the game itself. Nothing is ever
-- posted without the user pressing Post.
local GuildRecruit = {
    -- How long after an ad in a zone's General channel the next one is due.
    GENERAL_GAP_SECONDS = 60 * 60,
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
--   location    function() -> { key, name, general }: the zone's key and
--               name, and its General channel's number (nil when the user
--               isn't in it); nil when the zone is unknown
--   send        function(text, channelNumber) -> true when posted
--   view        { Show = function(view, prompts, handlers) }: draws the
--               prompts; handlers.post(key) answers Post
function GuildRecruit.Create(options)
    local recruit = setmetatable({
        partition = options.partition,
        selfKey = options.selfKey,
        store = options.store,
        now = options.now,
        canInvite = options.canInvite,
        location = options.location,
        send = options.send,
        view = options.view,
        -- The prompts on screen, in order.
        prompts = {},
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
    return addon.RecruitLedger.Create(partition and partition:GetRecruitLedger(), function()
        return GuildRecruit.GENERAL_GAP_SECONDS
    end)
end

-- The current location, or nil.
function Recruit:Location()
    local ok, location = pcall(self.location)
    if ok and type(location) == "table" then
        return location
    end
    return nil
end

-- The question a prompt asks.
function GuildRecruit.PromptText(prompt)
    return "Advertise in " .. tostring(prompt.zoneName or "this zone") .. " General?"
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
        ledger:Prune(now)
        due = self.policy:Due(self:Location(), ledger, now)
    end
    local index
    for index = 1, #due do
        due[index].text = GuildRecruit.PromptText(due[index])
    end
    self.prompts = due
    self:draw()
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
    if location == nil or location.key ~= prompt.zoneKey or type(location.general) ~= "number" then
        self:Refresh()
        return nil
    end
    local ok, sent = pcall(self.send, ad, location.general)
    if not ok or sent ~= true then
        return nil
    end
    self:Ledger():Record(key, now)
    self:Refresh()
    return ad
end
