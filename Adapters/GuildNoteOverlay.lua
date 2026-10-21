local _, addon = ...

-- Adds to the game's own guild roster: for officers, which members are
-- ready for promotion (an up arrow beside their rank: add-ons can't promote,
-- so the officer promotes them in the game's window), which members' public
-- notes are out of date (a marker on their rows) and what a selected
-- member's note should say (see NoteAudit), in a small panel to the right
-- of the member detail panel, level with its note; under the detail panel,
-- the selected member's player's promotion status (see
-- PromotionsViewModel.PanelRows): an officer's for anyone, to work on, and
-- a member's for their own player only, read-only; and for everyone, under
-- that (or straight under the detail panel), a mini profile of the selected
-- member's player (alias, Discord, location, bio, main and alts). Forever and Retail share
-- the Communities guild roster, so one overlay serves both.
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
    EDIT_TEXT = "Edit",
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
    -- The overlay's panels: their edge, the room inside them, and the gap
    -- between lines. The note panel is this wide; the profile panel is as
    -- wide as the detail panel, and shows at most PROFILE_LINES lines.
    NOTE_WIDTH = 240,
    PROFILE_LINES = 30,
    -- The profile panel sits this far right of the detail panel's edge, to
    -- clear the guild roster window, and leaves this much room above its
    -- Edit button.
    PROFILE_SHIFT = 6,
    EDIT_GAP = 10,
    PANEL_EDGE = 1,
    PANEL_PADDING = 8,
    LINE_GAP = 3,
    LINE_HEIGHT = 12,
    IGNORE_SIZE = { 64, 18 },
    -- The promotion panel, as wide as the profile panel: its lines this
    -- tall, at most this many (a longer list ends with a pointer to the
    -- add-on's panel).
    PROMOTION_LINE_HEIGHT = 20,
    PROMOTION_LINES = 18,
    PROMOTION_TITLE = "Promotion",
    PROMOTION_MORE = "|cff9d9d9dMore in the add-on's player panel|r",
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
--               named `name`'s player, { title, lines, own }, or nil when
--               the add-on has no record of them; `own` when that player is
--               the user's, who then gets an Edit button
--   editProfile function() -> opens the user's My Profile page
--   readyCheck  function() -> a function(name) telling whether the roster
--               member named `name` is ready for promotion, or nil when
--               nobody's flagged (members); asked once per redraw
--   promotionFor function(name) -> the promotion rows for the player of
--               the roster member named `name`, or nil when this user may
--               not see them (or there are none)
--   tick        function(key, item, ticked, note) -> true, or false and
--               why: an officer's tick, untick or override
--   toggle      function(key) -> opens or closes a character's checklist
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
        editProfile = options.editProfile or function() end,
        readyCheck = options.readyCheck or function()
            return nil
        end,
        promotionFor = options.promotionFor or function()
            return nil
        end,
        tick = options.tick or function()
            return false
        end,
        toggle = options.toggle or function() end,
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
        created:SetPoint("TOPLEFT", detail, "BOTTOMLEFT", GuildNoteOverlay.PROFILE_SHIFT, 0)
        created:SetPoint("TOPRIGHT", detail, "BOTTOMRIGHT", GuildNoteOverlay.PROFILE_SHIFT, 0)
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
        local edit = self.environment.CreateFrame("Button", nil, created, "UIPanelButtonTemplate")
        edit:SetSize(GuildNoteOverlay.IGNORE_SIZE[1], GuildNoteOverlay.IGNORE_SIZE[2])
        edit:SetPoint("BOTTOMRIGHT", created, "BOTTOMRIGHT", -padding, padding)
        edit:SetText(GuildNoteOverlay.EDIT_TEXT)
        edit:SetScript("OnClick", function()
            pcall(self.editProfile)
        end)
        edit:Hide()
        created.edit = edit
        created:Hide()
        return created
    end)
    self.profile = okProfile and profile or nil
    self:BuildPromotion(detail)
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
    self:ShowPromotion(name)
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
    -- The user's own player gets an Edit button at the bottom.
    local button = 0
    if summary.own then
        profile.edit:Show()
        button = GuildNoteOverlay.EDIT_GAP + GuildNoteOverlay.IGNORE_SIZE[2]
    else
        profile.edit:Hide()
    end
    profile:SetHeight(height(profile.title, 1) + GuildNoteOverlay.LINE_GAP
        + height(profile.body, math.max(#(summary.lines or {}), 1)) + button + 2 * GuildNoteOverlay.PANEL_PADDING)
    profile:Show()
end

-- Builds the promotion panel, hung under the detail panel like the profile
-- panel (which then hangs under it; see StackProfile): a title over
-- PROMOTION_LINES lines drawn by PromotionLines, made a child of the detail
-- panel so it shows and hides with it.
function Overlay:BuildPromotion(detail)
    local padding = GuildNoteOverlay.PANEL_PADDING
    local ok, promotion = pcall(function()
        local created = self:Box(detail)
        created:SetPoint("TOPLEFT", detail, "BOTTOMLEFT", GuildNoteOverlay.PROFILE_SHIFT, 0)
        created:SetPoint("TOPRIGHT", detail, "BOTTOMRIGHT", GuildNoteOverlay.PROFILE_SHIFT, 0)
        created.title = created:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        created.title:SetPoint("TOPLEFT", created, "TOPLEFT", padding, -padding)
        created.title:SetText(GuildNoteOverlay.PROMOTION_TITLE)
        created.state = addon.PromotionLines.State({
            createFrame = self.environment.CreateFrame,
            tooltip = self.environment.GameTooltip,
            tick = function(key, item, ticked, note)
                return self.tick(key, item, ticked, note)
            end,
            toggle = function(key)
                self.toggle(key)
                self:ShowPromotion(self.member)
            end,
            redraw = function()
                self:ShowPromotion(self.member)
            end,
        })
        created.lines = {}
        local index
        for index = 1, GuildNoteOverlay.PROMOTION_LINES do
            local line = self.environment.CreateFrame("Frame", nil, created)
            line:SetHeight(GuildNoteOverlay.PROMOTION_LINE_HEIGHT)
            local top = -padding - GuildNoteOverlay.LINE_HEIGHT - GuildNoteOverlay.LINE_GAP
                - (index - 1) * GuildNoteOverlay.PROMOTION_LINE_HEIGHT
            line:SetPoint("TOPLEFT", created, "TOPLEFT", padding, top)
            line:SetPoint("TOPRIGHT", created, "TOPRIGHT", -padding, top)
            line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            line.text:SetJustifyH("LEFT")
            line.text:SetWordWrap(false)
            addon.PromotionLines.Attach(line, created.state)
            line:Hide()
            created.lines[index] = line
        end
        created:Hide()
        return created
    end)
    self.promotion = ok and promotion or nil
end

-- Hangs the profile panel under the promotion panel while that shows, else
-- under the detail panel.
function Overlay:StackProfile()
    local profile = self.profile
    local detail = self:FindDetailFrame()
    if profile == nil or detail == nil then
        return
    end
    pcall(profile.ClearAllPoints, profile)
    local promotion = self.promotion
    if promotion ~= nil and promotion:IsShown() then
        profile:SetPoint("TOPLEFT", promotion, "BOTTOMLEFT", 0, 0)
        profile:SetPoint("TOPRIGHT", promotion, "BOTTOMRIGHT", 0, 0)
    else
        profile:SetPoint("TOPLEFT", detail, "BOTTOMLEFT", GuildNoteOverlay.PROFILE_SHIFT, 0)
        profile:SetPoint("TOPRIGHT", detail, "BOTTOMRIGHT", GuildNoteOverlay.PROFILE_SHIFT, 0)
    end
end

-- Shows the promotion status of the player of the member named `name`, or
-- hides it when this user may not see it.
function Overlay:ShowPromotion(name)
    local promotion = self.promotion
    if promotion == nil then
        return
    end
    local rows
    if name ~= nil then
        local ok, found = pcall(self.promotionFor, name)
        rows = ok and type(found) == "table" and found[1] ~= nil and found or nil
    end
    if rows == nil then
        promotion:Hide()
        self:StackProfile()
        return
    end
    local cap = GuildNoteOverlay.PROMOTION_LINES
    local shown = {}
    local index
    for index = 1, math.min(#rows, cap) do
        shown[index] = rows[index]
    end
    if #rows > cap then
        shown[cap] = { kind = "promotion", text = GuildNoteOverlay.PROMOTION_MORE }
    end
    for index = 1, cap do
        local line = promotion.lines[index]
        if shown[index] ~= nil then
            addon.PromotionLines.Draw(line, shown[index], promotion.state)
            line:Show()
        else
            line.row = nil
            line:Hide()
        end
    end
    promotion:SetHeight(2 * GuildNoteOverlay.PANEL_PADDING + GuildNoteOverlay.LINE_HEIGHT
        + GuildNoteOverlay.LINE_GAP + #shown * GuildNoteOverlay.PROMOTION_LINE_HEIGHT)
    promotion:Show()
    self:StackProfile()
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
    frame:Hide()
    return frame
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
        local ok, ready = false, false
        if check ~= nil then
            ok, ready = pcall(check, name)
        end
        if ok and ready == true then
            self:PlaceReady(row, readyMarker)
            readyMarker:Show()
        else
            readyMarker:Hide()
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
-- are followed, and how many show a Ready flag now.
function Overlay:ReadyProbeLines()
    if self.memberList == nil then
        return { "Guild roster rows followed: no (open the game's guild roster, then probe again)" }
    end
    self:MarkRows()
    local shown, rows, byRank = 0, 0, 0
    pcall(eachRow, self.memberList, function(row)
        rows = rows + 1
        local readyMarker = self.readyMarkers and self.readyMarkers[row]
        local ok, isShown = pcall(function()
            return readyMarker ~= nil and readyMarker:IsShown()
        end)
        if ok and isShown then
            shown = shown + 1
            if self.readyPlaces and self.readyPlaces[row] == "rank" then
                byRank = byRank + 1
            end
        end
    end)
    return {
        "Guild roster rows followed: yes (" .. rows .. " shown)",
        "Rows with a Ready flag now: " .. shown,
        "Flags next to the rank: " .. byRank .. "; at the row's right edge (no rank text found): " ..
            (shown - byRank),
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
