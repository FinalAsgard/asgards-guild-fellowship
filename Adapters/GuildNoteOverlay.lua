local _, addon = ...

-- Adds to the game's own guild roster: for officers, which members' public
-- notes are out of date (a marker on their rows) and what a selected
-- member's note should say (see NoteAudit), in a small panel to the right
-- of the member detail panel, level with its note; for everyone, a mini
-- profile of the selected member's player (alias, Discord, location, bio,
-- main and alts) in a panel hung under it. Forever and Retail share the
-- Communities guild roster, so one overlay serves both.
--
-- It only adds its own child frames and follows the game's frames with
-- hooksecurefunc and HookScript; nothing is drawn inside the game's panel.
-- It never replaces or calls the game's functions, and never writes a
-- note: officers retype the suggestion in the game's note editor.
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
    IGNORE_TEXT = "Ignore",
    -- The small marker on a roster row whose member's note is out of date.
    MARKER_TEXTURE = "Interface\\COMMON\\Indicator-Yellow",
    MARKER_SIZE = 12,
    -- The overlay's panels: their edge, the room inside them, and the gap
    -- between lines. The note panel is this wide; the profile panel is as
    -- wide as the detail panel, and shows at most PROFILE_LINES lines.
    NOTE_WIDTH = 240,
    PROFILE_LINES = 30,
    PANEL_EDGE = 1,
    PANEL_PADDING = 8,
    LINE_GAP = 3,
    LINE_HEIGHT = 12,
    IGNORE_SIZE = { 64, 18 },
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
--               named `name`, or nil when the note is up to date (or
--               ignored)
--   ignore      function(row) -> leaves the row's mismatch alone until its
--               note or suggestion changes (Partition:IgnoreNote); the
--               overlay redraws afterwards
--   profileFor  function(name) -> the mini profile of the roster member
--               named `name`'s player, { title, lines }, or nil when the
--               add-on has no record of them
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
        ignore = options.ignore or function() end,
        profileFor = options.profileFor or function()
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

-- A frame of the overlay's own on `parent`, with its own edge and dark
-- background.
function Overlay:Box(parent)
    local created = self.environment.CreateFrame("Frame", nil, parent)
    local edge = created:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints(created)
    edge:SetColorTexture(0.5, 0.5, 0.5, 0.8)
    local fill = created:CreateTexture(nil, "BORDER")
    fill:SetPoint("TOPLEFT", created, "TOPLEFT", GuildNoteOverlay.PANEL_EDGE, -GuildNoteOverlay.PANEL_EDGE)
    fill:SetPoint("BOTTOMRIGHT", created, "BOTTOMRIGHT", -GuildNoteOverlay.PANEL_EDGE, GuildNoteOverlay.PANEL_EDGE)
    fill:SetColorTexture(0, 0, 0, 0.9)
    return created
end

-- Builds the note panel, to the right of the detail panel, and the profile
-- panel, hung under it: the overlay's own frames, made children of the
-- detail panel only so they show and hide with it. Safe to call again; it
-- attaches once.
function Overlay:Attach()
    if self.panel ~= nil then
        return true
    end
    local detail = self:FindDetailFrame()
    local hook = self.environment.hooksecurefunc
    if detail == nil or type(hook) ~= "function" or type(self.environment.CreateFrame) ~= "function" then
        return false
    end
    local padding = GuildNoteOverlay.PANEL_PADDING
    local ok, panel = pcall(function()
        local created = self:Box(detail)
        created:SetPoint("TOPLEFT", detail, "TOPRIGHT", 0, 0)
        created:SetWidth(GuildNoteOverlay.NOTE_WIDTH)
        local button = self.environment.CreateFrame("Button", nil, created, "UIPanelButtonTemplate")
        button:SetSize(GuildNoteOverlay.IGNORE_SIZE[1], GuildNoteOverlay.IGNORE_SIZE[2])
        button:SetPoint("TOPRIGHT", created, "TOPRIGHT", -padding, -padding)
        button:SetText(GuildNoteOverlay.IGNORE_TEXT)
        button:SetScript("OnClick", function()
            self:IgnoreShown()
        end)
        created.ignore = button
        local function line(anchor, font)
            local text = created:CreateFontString(nil, "OVERLAY", font)
            if anchor == nil then
                text:SetPoint("TOPLEFT", created, "TOPLEFT", padding, -padding)
            else
                text:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -GuildNoteOverlay.LINE_GAP)
            end
            text:SetPoint("RIGHT", created, "RIGHT", -padding, 0)
            text:SetJustifyH("LEFT")
            return text
        end
        created.suggested = line(nil, "GameFontHighlightSmall")
        created.suggested:SetPoint("RIGHT", button, "LEFT", -4, 0)
        created.problems = line(created.suggested, "GameFontNormalSmall")
        created.tooLong = line(created.problems, "GameFontRedSmall")
        created:Hide()
        return created
    end)
    if not ok or panel == nil then
        return false
    end
    local okProfile, profile = pcall(function()
        local created = self:Box(detail)
        created:SetPoint("TOPLEFT", detail, "BOTTOMLEFT", 0, 0)
        created:SetPoint("TOPRIGHT", detail, "BOTTOMRIGHT", 0, 0)
        created.title = created:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        created.title:SetPoint("TOPLEFT", created, "TOPLEFT", padding, -padding)
        created.title:SetPoint("RIGHT", created, "RIGHT", -padding, 0)
        created.title:SetJustifyH("LEFT")
        created.body = created:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        created.body:SetPoint("TOPLEFT", created.title, "BOTTOMLEFT", 0, -GuildNoteOverlay.LINE_GAP)
        created.body:SetPoint("RIGHT", created, "RIGHT", -padding, 0)
        created.body:SetJustifyH("LEFT")
        if type(created.body.SetMaxLines) == "function" then
            created.body:SetMaxLines(GuildNoteOverlay.PROFILE_LINES)
        end
        created:Hide()
        return created
    end)
    self.profile = okProfile and profile or nil
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

-- Shows the panels for the member named `name`, or hides them. The note
-- panel is for officers, for a member whose note is out of date; the
-- profile panel for anyone, for a member the add-on has a record of.
function Overlay:ShowMember(name)
    self.member = name
    local panel = self.panel
    if panel == nil then
        return
    end
    self:ShowProfile(name)
    local row
    if name ~= nil and self.isOfficer() then
        local ok, found = pcall(self.rowFor, name)
        row = ok and found or nil
    end
    self.shownRow = row
    if row == nil then
        panel:Hide()
        return
    end
    local lines = GuildNoteOverlay.Lines(row)
    panel.suggested:SetText(lines.suggested)
    panel.problems:SetText(lines.problems)
    panel.tooLong:SetText(lines.tooLong)
    panel:SetHeight(self:PanelHeight(panel))
    self:AlignWithNote(panel)
    panel:Show()
end

-- Moves the note panel down to the detail panel's public note, where the
-- client can say where that is; else it stays level with the panel's top.
function Overlay:AlignWithNote(panel)
    local detail = self:FindDetailFrame()
    local note = detail and detail.NoteBackground
    local offset = 0
    if type(note) == "table" then
        local okNote, noteTop = pcall(note.GetTop, note)
        local okDetail, detailTop = pcall(detail.GetTop, detail)
        if okNote and okDetail and type(noteTop) == "number" and type(detailTop) == "number" then
            offset = noteTop - detailTop
        end
    end
    pcall(panel.ClearAllPoints, panel)
    panel:SetPoint("TOPLEFT", detail, "TOPRIGHT", 0, offset)
end

-- Shows the mini profile of the member named `name`'s player, or hides it.
function Overlay:ShowProfile(name)
    local profile = self.profile
    if profile == nil then
        return
    end
    local summary
    if name ~= nil then
        local ok, found = pcall(self.profileFor, name)
        summary = ok and type(found) == "table" and found or nil
    end
    if summary == nil then
        profile:Hide()
        return
    end
    profile.title:SetText(summary.title or name)
    profile.body:SetText(table.concat(summary.lines or {}, "\n"))
    local function height(text, lines)
        local ok, found = pcall(text.GetStringHeight, text)
        return ok and type(found) == "number" and found > 0 and found or GuildNoteOverlay.LINE_HEIGHT * lines
    end
    profile:SetHeight(height(profile.title, 1) + GuildNoteOverlay.LINE_GAP
        + height(profile.body, math.max(#(summary.lines or {}), 1)) + 2 * GuildNoteOverlay.PANEL_PADDING)
    profile:Show()
end

-- The panel's height for the lines it shows now: each line as tall as its
-- wrapped text where the client says, the Ignore button's height at least
-- for the first.
function Overlay:PanelHeight(panel)
    local function height(text)
        local ok, found = pcall(text.GetStringHeight, text)
        return ok and type(found) == "number" and found > 0 and found or GuildNoteOverlay.LINE_HEIGHT
    end
    local total = math.max(height(panel.suggested), GuildNoteOverlay.IGNORE_SIZE[2])
    local lines = { panel.problems, panel.tooLong }
    local index
    for index = 1, #lines do
        local text = lines[index]
        local ok, shown = pcall(text.GetText, text)
        if ok and type(shown) == "string" and shown ~= "" then
            total = total + GuildNoteOverlay.LINE_GAP + height(text)
        end
    end
    return total + 2 * GuildNoteOverlay.PANEL_PADDING
end

-- The Ignore button: leaves the shown member's mismatch alone, then hides
-- it from the panel and the row markers.
function Overlay:IgnoreShown()
    local row = self.shownRow
    if row == nil or not self.isOfficer() then
        return
    end
    pcall(self.ignore, row)
    self:Refresh()
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
