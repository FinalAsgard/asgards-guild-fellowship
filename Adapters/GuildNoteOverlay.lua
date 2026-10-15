local _, addon = ...

-- Shows officers, in the game's own guild roster, which members' public
-- notes are out of date (a marker on their rows) and what a selected
-- member's note should say (see NoteAudit). Forever and Retail
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
    -- The small marker on a roster row whose member's note is out of date.
    MARKER_TEXTURE = "Interface\\COMMON\\Indicator-Yellow",
    MARKER_SIZE = 12,
    -- Member list methods that redraw its rows (scrolling, sorting, and
    -- roster refreshes all end in one of these); hooked where they exist.
    LIST_REFRESHES = { "RefreshListDisplay", "RefreshLayout", "Update" },
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

-- The guild roster's member list, or nil when it isn't loaded.
function Overlay:FindMemberList()
    local communities = self.environment.CommunitiesFrame
    local list = type(communities) == "table" and communities.MemberList or nil
    return type(list) == "table" and list or nil
end

-- The member list's row frames shown now: a scroll box's frames, or an
-- older scroll frame's buttons.
local function eachRow(list, callback)
    local scrollBox = list.ScrollBox
    if type(scrollBox) == "table" and type(scrollBox.ForEachFrame) == "function" then
        scrollBox:ForEachFrame(callback)
        return
    end
    local scroll = list.ListScrollFrame
    local buttons = type(scroll) == "table" and scroll.buttons or nil
    if type(buttons) == "table" then
        local index
        for index = 1, #buttons do
            callback(buttons[index])
        end
    end
end

-- The roster name a row shows, or nil.
local function rowName(row)
    local info = row.memberInfo
    if info == nil and type(row.GetMemberInfo) == "function" then
        local ok, found = pcall(row.GetMemberInfo, row)
        info = ok and found or nil
    end
    return type(info) == "table" and info.name or nil
end

-- Shows or hides `row`'s marker for its current member. The marker is the
-- overlay's own child frame, made the first time the row is drawn; the row
-- itself is only followed (its SetMember hooked), never changed.
function Overlay:MarkRow(row)
    if type(row) ~= "table" then
        return
    end
    self.rows = self.rows or setmetatable({}, { __mode = "k" })
    local marker = self.rows[row]
    if marker == nil then
        local ok, created = pcall(function()
            local frame = self.environment.CreateFrame("Frame", nil, row)
            frame:SetSize(GuildNoteOverlay.MARKER_SIZE, GuildNoteOverlay.MARKER_SIZE)
            frame:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            local texture = frame:CreateTexture(nil, "OVERLAY")
            texture:SetAllPoints(frame)
            texture:SetTexture(GuildNoteOverlay.MARKER_TEXTURE)
            frame:Hide()
            return frame
        end)
        if not ok or created == nil then
            return
        end
        marker = created
        self.rows[row] = marker
        -- Scrolling reuses rows for other members: follow each new one.
        if type(row.SetMember) == "function" then
            pcall(self.environment.hooksecurefunc, row, "SetMember", function(drawn)
                self:MarkRow(drawn)
            end)
        end
    end
    local name = rowName(row)
    local outOfDate = false
    if name ~= nil and self.isOfficer() then
        local ok, found = pcall(self.rowFor, name)
        outOfDate = ok and found ~= nil
    end
    if outOfDate then
        marker:Show()
    else
        marker:Hide()
    end
end

-- Marks every row the member list shows now.
function Overlay:MarkRows()
    if self.memberList == nil then
        return
    end
    pcall(eachRow, self.memberList, function(row)
        self:MarkRow(row)
    end)
end

-- Follows the member list's redraws. Safe to call again; it hooks once.
function Overlay:AttachRows()
    if self.memberList ~= nil then
        return true
    end
    local list = self:FindMemberList()
    local hook = self.environment.hooksecurefunc
    if list == nil or type(hook) ~= "function" or type(self.environment.CreateFrame) ~= "function" then
        return false
    end
    local hooked = false
    local index
    for index = 1, #GuildNoteOverlay.LIST_REFRESHES do
        local method = GuildNoteOverlay.LIST_REFRESHES[index]
        if type(list[method]) == "function" and pcall(hook, list, method, function()
            self:MarkRows()
        end) then
            hooked = true
        end
    end
    if not hooked then
        return false
    end
    self.memberList = list
    self:MarkRows()
    return true
end

-- After a scan, sync, or manual change: redraws the member shown now and
-- the row markers.
function Overlay:Refresh()
    if self.member ~= nil then
        self:ShowMember(self.member)
    end
    self:MarkRows()
end

-- Attaches now if the guild roster is loaded, or when it loads.
function Overlay:Start()
    local rows = self:AttachRows()
    if self:Attach() and rows then
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
                self:AttachRows()
            end
        end
    end)
    self.client:RegisterEvent(frame, "ADDON_LOADED")
    self.watcher = frame
end
