local _, addon = ...

-- Adds to the game's own guild roster: for officers, which members are
-- ready for promotion (an up arrow beside their rank: add-ons can't promote,
-- so the officer promotes them in the game's window) or alts to promote to
-- match their player (the same arrow, tinted), which members' public
-- notes are out of date (a marker on their rows) and what a selected
-- member's note should say (see NoteAudit), in a small panel to the right
-- of the member detail panel, level with its note. For everyone, selecting
-- a member the add-on knows opens the add-on's player panel for their
-- player. Forever and Retail share the Communities guild roster, so one
-- overlay serves both.
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
    -- The flag on a roster row whose member is ready for promotion: the
    -- game's up arrow, on both clients, READY_GAP after the row's rank text.
    -- A row with no rank text shown (best guess: the Communities row's
    -- `Rank` font string; see /agf probe ready) gets it left of the note
    -- marker instead, READY_OFFSET in from its right edge.
    READY_TEXTURE = "Interface\\Buttons\\Arrow-Up-Up",
    READY_SIZE = 16,
    READY_GAP = 4,
    READY_OFFSET = -20,
    -- A Promote to match flag is the same arrow tinted MATCH_TINT (the
    -- blue of the panels' "Promote to match" lines, |cff4da6ff), with a
    -- tooltip. The tint is a best guess at one that's easy to tell apart
    -- from the plain arrow; it's checked in game on the PRD's HITL issue.
    MATCH_TINT = { 0.30, 0.65, 1.00 },
    MATCH_TOOLTIP = "Promote to match: %s",
    -- The note panel: its edge, the room inside it, the gap between lines,
    -- and its width.
    NOTE_WIDTH = 240,
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
--   showPlayer  function(name) -> opens the add-on's player panel for the
--               player of the roster member named `name`, when it knows
--               them
--   readyCheck  function() -> a function(name) giving the roster member
--               named `name`'s flag: "ready" (ready for promotion), or
--               "match" and the rank name to promote them to (which wins
--               over ready), or nil for none; or nil when nobody's flagged
--               (members); asked once per redraw
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
        showPlayer = options.showPlayer or function() end,
        readyCheck = options.readyCheck or function()
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

-- Builds the note panel, to the right of the detail panel: the overlay's
-- own frame, made a child of the detail panel only so it shows and hides
-- with it, and follows which member the detail panel shows. Safe to call
-- again; it attaches once.
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
    local hooked = pcall(hook, detail, "DisplayMember", function(_, _, memberInfo)
        self:SelectMember(type(memberInfo) == "table" and memberInfo.name or nil)
    end)
    if not hooked then
        return false
    end
    if type(detail.HookScript) == "function" then
        pcall(detail.HookScript, detail, "OnHide", function()
            self:SelectMember(nil)
        end)
    end
    self.panel = panel
    return true
end

-- The detail panel shows the member named `name` (nil when it closes):
-- opens the add-on's player panel for a newly selected member, then shows
-- the note panel. Showing the same member again (the game redraws the
-- detail panel on roster updates) doesn't reopen a player panel the user
-- closed.
function Overlay:SelectMember(name)
    local changed = name ~= self.member
    self:ShowMember(name)
    if changed and name ~= nil then
        pcall(self.showPlayer, name)
    end
end

-- Shows the note panel for the member named `name`, or hides it: for
-- officers, for a member whose note is out of date.
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

-- The ready check for this redraw (see readyCheck), worked out on first use.
function Overlay:ReadyCheck()
    if self.ready == nil then
        local ok, check = false, nil
        if self.isOfficer() then
            ok, check = pcall(self.readyCheck)
        end
        self.ready = ok and type(check) == "function" and check or false
    end
    return self.ready or nil
end

-- One of a row's markers: the overlay's own child frame, `size` square,
-- `offset` in from the row's right edge, showing `texture`.
function Overlay:Marker(row, size, offset, texture)
    local frame = self.environment.CreateFrame("Frame", nil, row)
    frame:SetSize(size, size)
    frame:SetPoint("RIGHT", row, "RIGHT", offset, 0)
    local picture = frame:CreateTexture(nil, "OVERLAY")
    picture:SetAllPoints(frame)
    picture:SetTexture(texture)
    frame.picture = picture
    frame:Hide()
    return frame
end

-- Sets the flag `marker` shows: "ready" (the plain arrow) or "match" to
-- `rankName` (tinted, with a tooltip). Only a match flag takes the mouse,
-- for its tooltip, and clicks still go to the row. Where clicks can't be
-- passed through (no SetMouseClickEnabled), the flag never takes the
-- mouse and goes without its tooltip, so the row keeps its clicks.
function Overlay:SetFlag(marker, kind, rankName)
    local tint = kind == "match" and GuildNoteOverlay.MATCH_TINT or { 1, 1, 1 }
    pcall(marker.picture.SetVertexColor, marker.picture, tint[1], tint[2], tint[3])
    marker.tooltip = kind == "match" and string.format(GuildNoteOverlay.MATCH_TOOLTIP, tostring(rankName)) or nil
    local hover = marker.tooltip ~= nil and type(marker.SetMouseClickEnabled) == "function"
    pcall(marker.EnableMouse, marker, hover)
    if hover and not pcall(marker.SetMouseClickEnabled, marker, false) then
        pcall(marker.EnableMouse, marker, false)
    end
    if not marker.hasTooltip then
        marker.hasTooltip = true
        local environment = self.environment
        pcall(marker.SetScript, marker, "OnEnter", function()
            local tooltip = environment.GameTooltip
            if marker.tooltip ~= nil and tooltip ~= nil then
                pcall(tooltip.SetOwner, tooltip, marker, "ANCHOR_RIGHT")
                pcall(tooltip.SetText, tooltip, marker.tooltip)
                pcall(tooltip.Show, tooltip)
            end
        end)
        pcall(marker.SetScript, marker, "OnLeave", function()
            local tooltip = environment.GameTooltip
            if tooltip ~= nil then
                pcall(tooltip.Hide, tooltip)
            end
        end)
    end
end

-- Shows or hides `row`'s markers for its current member. They're the
-- overlay's own child frames, made the first time the row is drawn; the
-- row itself is only followed (its SetMember hooked), never changed.
function Overlay:MarkRow(row)
    if type(row) ~= "table" then
        return
    end
    self.rows = self.rows or setmetatable({}, { __mode = "k" })
    self.readyMarkers = self.readyMarkers or setmetatable({}, { __mode = "k" })
    local marker = self.rows[row]
    if marker == nil then
        local ok, created, ready = pcall(function()
            return self:Marker(row, GuildNoteOverlay.MARKER_SIZE, -4, GuildNoteOverlay.MARKER_TEXTURE),
                self:Marker(row, GuildNoteOverlay.READY_SIZE, GuildNoteOverlay.READY_OFFSET,
                    GuildNoteOverlay.READY_TEXTURE)
        end)
        if not ok or created == nil then
            return
        end
        marker = created
        self.rows[row] = marker
        self.readyMarkers[row] = ready
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
    local readyMarker = self.readyMarkers[row]
    if readyMarker ~= nil then
        local check = name ~= nil and self:ReadyCheck() or nil
        local ok, kind, rankName = false, nil, nil
        if check ~= nil then
            ok, kind, rankName = pcall(check, name)
        end
        self.readyKinds = self.readyKinds or setmetatable({}, { __mode = "k" })
        if ok and (kind == "ready" or kind == "match") then
            self:SetFlag(readyMarker, kind, rankName)
            self:PlaceReady(row, readyMarker)
            readyMarker:Show()
            self.readyKinds[row] = kind
        else
            readyMarker:Hide()
            self.readyKinds[row] = nil
        end
    end
end

-- `row`'s rank text, when the row has one shown.
local function rankText(row)
    local rank = row.Rank
    if type(rank) ~= "table" or type(rank.GetStringWidth) ~= "function" then
        return nil
    end
    if type(rank.IsShown) == "function" then
        local ok, shown = pcall(rank.IsShown, rank)
        if ok and shown == false then
            return nil
        end
    end
    return rank
end

-- Puts `row`'s Ready flag just after its rank text (no further than the
-- rank column's edge), or, with no rank text, left of the note marker.
-- Remembers where, for /agf probe ready.
function Overlay:PlaceReady(row, marker)
    local rank = rankText(row)
    pcall(marker.ClearAllPoints, marker)
    self.readyPlaces = self.readyPlaces or setmetatable({}, { __mode = "k" })
    if rank ~= nil then
        local okText, text = pcall(rank.GetStringWidth, rank)
        local width = okText and type(text) == "number" and text or 0
        if type(rank.GetWidth) == "function" then
            local okColumn, column = pcall(rank.GetWidth, rank)
            if okColumn and type(column) == "number" and column > 0 then
                width = math.min(width, column)
            end
        end
        marker:SetPoint("LEFT", rank, "LEFT", width + GuildNoteOverlay.READY_GAP, 0)
        self.readyPlaces[row] = "rank"
        return
    end
    marker:SetPoint("RIGHT", row, "RIGHT", GuildNoteOverlay.READY_OFFSET, 0)
    self.readyPlaces[row] = "edge"
end

-- Marks every row the member list shows now, with the ready check worked
-- out afresh.
function Overlay:MarkRows()
    self.ready = nil
    if self.memberList == nil then
        return
    end
    pcall(eachRow, self.memberList, function(row)
        self:MarkRow(row)
    end)
end

-- What /agf probe ready prints about the guild roster: whether its rows
-- are followed, and how many show a Ready flag and a Promote to match flag
-- now.
function Overlay:ReadyProbeLines()
    if self.memberList == nil then
        return { "Guild roster rows followed: no (open the game's guild roster, then probe again)" }
    end
    self:MarkRows()
    local shown, rows, byRank, matches = 0, 0, 0, 0
    pcall(eachRow, self.memberList, function(row)
        rows = rows + 1
        local readyMarker = self.readyMarkers and self.readyMarkers[row]
        local ok, isShown = pcall(function()
            return readyMarker ~= nil and readyMarker:IsShown()
        end)
        if ok and isShown then
            if self.readyKinds and self.readyKinds[row] == "match" then
                matches = matches + 1
            end
            shown = shown + 1
            if self.readyPlaces and self.readyPlaces[row] == "rank" then
                byRank = byRank + 1
            end
        end
    end)
    return {
        "Guild roster rows followed: yes (" .. rows .. " shown)",
        "Rows with a Ready flag now: " .. (shown - matches),
        "Flags next to the rank: " .. byRank .. "; at the row's right edge (no rank text found): " ..
            (shown - byRank),
        "Rows with a Promote to match flag now: " .. matches,
    }
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
