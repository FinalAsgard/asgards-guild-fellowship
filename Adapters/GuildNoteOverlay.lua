local _, addon = ...

-- Shows officers, in the game's own guild roster, what a selected member's
-- out-of-date public note should say (see NoteAudit). Forever and Retail
-- share the Communities guild roster, so one overlay serves both.
--
-- It only adds its own child frames to the member detail panel and follows
-- the game's frames with hooksecurefunc and HookScript. It never replaces
-- or calls the game's functions, and never writes a note: officers retype
-- the suggestion in the game's note editor.
local GuildNoteOverlay = {
    -- The guild roster loads on demand; the overlay attaches when it does.
    GUILD_ADDONS = { "Blizzard_Communities" },
    PROBLEM_TEXT = {
        ["missing main"] = "No main marker",
        ["wrong player"] = "Main marker names the wrong player",
        ["stale main"] = "Main marker shouldn't be there",
        ["missing alias"] = "Alias missing",
        ["wrong alias"] = "Wrong alias",
        ["unreadable main"] = "Main marker can't be read",
    },
    TOO_LONG_TEXT = "Too long for a public note: the other text has to be trimmed.",
}
addon.GuildNoteOverlay = GuildNoteOverlay

local Overlay = {}
Overlay.__index = Overlay

-- options:
--   client      the compatibility adapter
--   isOfficer   function() -> true when the logged-in character is an
--               officer (OfficerAuthority); nobody else sees anything
--   rowFor      function(name) -> the NoteAudit row for the roster member
--               named `name`, or nil when the note is up to date
function GuildNoteOverlay.Create(options)
    return setmetatable({
        client = options.client,
        environment = options.client.environment,
        isOfficer = options.isOfficer or function()
            return false
        end,
        rowFor = options.rowFor or function()
            return nil
        end,
    }, Overlay)
end

-- The lines the panel shows for an audit row: the suggestion, the
-- problems, and a too-long warning when there is one.
function GuildNoteOverlay.Lines(row)
    local suggested = row.suggested ~= "" and row.suggested or "(empty)"
    local problems = {}
    local index
    for index = 1, #(row.problems or {}) do
        table.insert(problems, GuildNoteOverlay.PROBLEM_TEXT[row.problems[index]] or row.problems[index])
    end
    return {
        suggested = "Should be: " .. suggested,
        problems = table.concat(problems, "; "),
        tooLong = row.tooLong and GuildNoteOverlay.TOO_LONG_TEXT or "",
    }
end

-- The guild roster's member detail panel, or nil when it isn't loaded.
function Overlay:FindDetailFrame()
    local communities = self.environment.CommunitiesFrame
    if type(communities) ~= "table" then
        return nil
    end
    local detail = communities.GuildMemberDetailFrame
    if type(detail) ~= "table" or type(detail.DisplayMember) ~= "function" then
        return nil
    end
    return detail
end

-- Builds the panel just above the public note, as the detail panel's own
-- child. Safe to call again; it attaches once.
function Overlay:Attach()
    if self.panel ~= nil then
        return true
    end
    local detail = self:FindDetailFrame()
    local hook = self.environment.hooksecurefunc
    if detail == nil or type(hook) ~= "function" or type(self.environment.CreateFrame) ~= "function" then
        return false
    end
    local ok, panel = pcall(function()
        local created = self.environment.CreateFrame("Frame", nil, detail)
        local note = type(detail.NoteBackground) == "table" and detail.NoteBackground or nil
        if note ~= nil then
            created:SetPoint("BOTTOMLEFT", note, "TOPLEFT", 0, 16)
            created:SetPoint("BOTTOMRIGHT", note, "TOPRIGHT", 0, 16)
        else
            created:SetPoint("TOPLEFT", detail, "BOTTOMLEFT", 0, -4)
            created:SetPoint("TOPRIGHT", detail, "BOTTOMRIGHT", 0, -4)
        end
        created:SetHeight(42)
        local function line(anchor, font)
            local text = created:CreateFontString(nil, "OVERLAY", font)
            if anchor == nil then
                text:SetPoint("TOPLEFT", created, "TOPLEFT", 0, 0)
            else
                text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
            end
            text:SetPoint("RIGHT", created, "RIGHT", 0, 0)
            text:SetJustifyH("LEFT")
            return text
        end
        created.suggested = line(nil, "GameFontHighlightSmall")
        created.problems = line(created.suggested, "GameFontNormalSmall")
        created.tooLong = line(created.problems, "GameFontRedSmall")
        created:Hide()
        return created
    end)
    if not ok or panel == nil then
        return false
    end
    local hooked = pcall(hook, detail, "DisplayMember", function(_, _, memberInfo)
        self:ShowMember(type(memberInfo) == "table" and memberInfo.name or nil)
    end)
    if not hooked then
        return false
    end
    if type(detail.HookScript) == "function" then
        pcall(detail.HookScript, detail, "OnHide", function()
            self:ShowMember(nil)
        end)
    end
    self.panel = panel
    return true
end

-- Shows the panel for the member named `name`, or hides it: for anyone
-- but an officer, a member whose note is up to date, or nil.
function Overlay:ShowMember(name)
    self.member = name
    local panel = self.panel
    if panel == nil then
        return
    end
    local row
    if name ~= nil and self.isOfficer() then
        local ok, found = pcall(self.rowFor, name)
        row = ok and found or nil
    end
    if row == nil then
        panel:Hide()
        return
    end
    local lines = GuildNoteOverlay.Lines(row)
    panel.suggested:SetText(lines.suggested)
    panel.problems:SetText(lines.problems)
    panel.tooLong:SetText(lines.tooLong)
    panel:Show()
end

-- After a scan, sync, or manual change: redraws the member shown now.
function Overlay:Refresh()
    if self.member ~= nil then
        self:ShowMember(self.member)
    end
end

-- Attaches now if the guild roster is loaded, or when it loads.
function Overlay:Start()
    if self:Attach() then
        return
    end
    local frame = self.client:CreateEventFrame()
    if frame == nil then
        return
    end
    self.client:SetEventHandler(frame, function(_, eventName, loaded)
        if eventName ~= "ADDON_LOADED" then
            return
        end
        local index
        for index = 1, #GuildNoteOverlay.GUILD_ADDONS do
            if loaded == GuildNoteOverlay.GUILD_ADDONS[index] then
                self:Attach()
            end
        end
    end)
    self.client:RegisterEvent(frame, "ADDON_LOADED")
    self.watcher = frame
end
