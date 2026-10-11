local _, addon = ...

-- Guild Recruit's officer settings: the guild ad and whether it's on, the
-- gaps between ads in a zone's General and in Trade, and a guild-wide
-- pause. Pure:
-- it keeps them in the saved table it's given, one per guild, so they last
-- across reloads and logouts.
--
-- Each setting is saved as { value, at, by }: its value, and when (server
-- time) and by whom (a character key) it last changed. The newest change
-- wins, with sync's tie-break (time, then author), so every add-on settles
-- on the same value. A setting nobody has changed has its default. Only
-- changes by officers are accepted.
local RecruitConfig = {
    -- The longest guild ad: one chat message.
    AD_MAX = 255,
    -- The longest gap an officer can set, in minutes: a day.
    GAP_MAX_MINUTES = 24 * 60,
}
addon.RecruitConfig = RecruitConfig

-- Every officer setting: its default, and whether a value is acceptable.
RecruitConfig.SETTINGS = {
    guildAd = {
        default = "",
        valid = function(value)
            return type(value) == "string" and string.len(value) <= RecruitConfig.AD_MAX
        end,
    },
    guildAdOn = {
        default = true,
        valid = function(value)
            return type(value) == "boolean"
        end,
    },
    -- Gaps in whole minutes, never below a minimum, so no setting can turn
    -- the guild into spammers.
    generalGapMinutes = { default = 60, min = 15 },
    tradeGapMinutes = { default = 20, min = 5 },
    -- True stops every member's advertise prompts.
    paused = {
        default = false,
        valid = function(value)
            return type(value) == "boolean"
        end,
    },
}

-- A gap setting accepts whole minutes from its minimum to GAP_MAX_MINUTES.
local function gapValidator(setting)
    return function(value)
        return type(value) == "number" and value == math.floor(value)
            and value >= setting.min and value <= RecruitConfig.GAP_MAX_MINUTES
    end
end
RecruitConfig.SETTINGS.generalGapMinutes.valid = gapValidator(RecruitConfig.SETTINGS.generalGapMinutes)
RecruitConfig.SETTINGS.tradeGapMinutes.valid = gapValidator(RecruitConfig.SETTINGS.tradeGapMinutes)

local Config = {}
Config.__index = Config

-- `saved` is the table to keep settings in (nil keeps them only in memory).
-- options.isOfficer(key) -> true when the character is an officer.
function RecruitConfig.Create(saved, options)
    options = options or {}
    return setmetatable({
        settings = type(saved) == "table" and saved or {},
        isOfficer = options.isOfficer or function()
            return false
        end,
    }, Config)
end

local function isStamp(at, by)
    return type(at) == "number" and at == at and type(by) == "string" and by ~= ""
end

-- The saved entry for `name` ({ value, at, by }), or nil when it's unset or
-- unusable.
function Config:entry(name)
    local setting = RecruitConfig.SETTINGS[name]
    local entry = self.settings[name]
    if setting == nil or type(entry) ~= "table" or not setting.valid(entry.value) or not isStamp(entry.at, entry.by) then
        return nil
    end
    return entry
end

-- The setting's value, or its default.
function Config:Get(name)
    local entry = self:entry(name)
    if entry ~= nil then
        return entry.value
    end
    local setting = RecruitConfig.SETTINGS[name]
    return setting and setting.default
end

-- An officer (`by`, a character key) changes a setting at `at`. The change is
-- stamped later than the one it replaces, so a second change in the same
-- second still wins everywhere. Returns the saved entry, or nil when the
-- value is unacceptable or `by` isn't an officer.
function Config:Set(name, value, at, by)
    local setting = RecruitConfig.SETTINGS[name]
    local ok, officer = pcall(self.isOfficer, by)
    if setting == nil or not setting.valid(value) or not isStamp(at, by) or not ok or officer ~= true then
        return nil
    end
    local held = self:entry(name)
    if held ~= nil and at <= held.at then
        at = held.at + 1
    end
    local entry = { value = value, at = at, by = by }
    self.settings[name] = entry
    return entry
end

-- A received change to a setting. Applied when its value is acceptable, its
-- author is an officer, and it's newer than the one held. Returns true when
-- applied.
function Config:Apply(name, entry)
    local setting = RecruitConfig.SETTINGS[name]
    if setting == nil or type(entry) ~= "table" or not setting.valid(entry.value) or not isStamp(entry.at, entry.by) then
        return false
    end
    local ok, officer = pcall(self.isOfficer, entry.by)
    if not ok or officer ~= true then
        return false
    end
    local held = self:entry(name)
    if held ~= nil and not addon.SyncFacts.IsNewer(entry.at, entry.by, held.at, held.by) then
        return false
    end
    self.settings[name] = { value = entry.value, at = entry.at, by = entry.by }
    return true
end

-- Every setting that has been changed, by name ({ value, at, by } each), for
-- sending to other add-on users. Nil when nothing has been changed.
function Config:Changes()
    local changes
    local name
    for name in pairs(RecruitConfig.SETTINGS) do
        local entry = self:entry(name)
        if entry ~= nil then
            changes = changes or {}
            changes[name] = { value = entry.value, at = entry.at, by = entry.by }
        end
    end
    return changes
end

-- True when `changes` (from Changes) holds, for every setting changed here,
-- the same change or a newer one: nothing here would be news to whoever
-- sent it.
function Config:CoveredBy(changes)
    if type(changes) ~= "table" then
        return false
    end
    local name
    for name in pairs(RecruitConfig.SETTINGS) do
        local held = self:entry(name)
        local heard = changes[name]
        if held ~= nil and (type(heard) ~= "table" or not isStamp(heard.at, heard.by)
            or addon.SyncFacts.IsNewer(held.at, held.by, heard.at, heard.by))
        then
            return false
        end
    end
    return true
end

-- One ad picked at random from the usable ones, or nil when none is usable.
-- options:
--   officerAd     the guild ad's text
--   officerOn     true when the guild ad is on
--   useOfficer    true when the user posts the guild ad
--   ownAd         the user's own ad
--   random        function(low, high) -> a whole number
-- An ad of only spaces isn't usable.
function RecruitConfig.PickAd(options)
    local ads = {}
    local function usable(text)
        return type(text) == "string" and string.find(text, "%S") ~= nil
    end
    if options.useOfficer and options.officerOn and usable(options.officerAd) then
        table.insert(ads, options.officerAd)
    end
    if usable(options.ownAd) then
        table.insert(ads, options.ownAd)
    end
    if #ads <= 1 then
        return ads[1]
    end
    local ok, index = pcall(options.random, 1, #ads)
    if not ok or type(index) ~= "number" or ads[index] == nil then
        index = 1
    end
    return ads[index]
end
