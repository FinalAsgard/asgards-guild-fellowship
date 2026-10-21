local _, addon = ...

-- Draws the Promotion rows (PromotionsViewModel.PanelRows) on list lines:
-- a character's line opens or closes its checklist when clicked; an item
-- has a check box (an officer ticks a custom item with it, otherwise it
-- shows whether the item is met); a needs-a-note item's note, or a failed
-- check's override reason, is typed on the line under it; and an automated
-- item has Override or Undo override. Used by the player panel's Promotion
-- tab and the game guild roster's promotion panel, so both work the same.
local PromotionLines = {}
addon.PromotionLines = PromotionLines

-- The shared state of one list's lines. options:
--   createFrame(type, name, parent, template)
--   tooltip       GameTooltip, or nil
--   tick(key, item, ticked, note) -> true when saved
--   toggle(key)   opens or closes a character's checklist
--   redraw()      draws the lines again (to ask for a missing note)
-- Notes typed are kept, by character and item, while the list redraws
-- until they're saved (a line shows its item's saved note otherwise);
-- `noteNeeded` holds the items ticked before a note was typed.
function PromotionLines.State(options)
    local state = {
        createFrame = options.createFrame,
        tooltip = options.tooltip,
        notes = {},
        noteNeeded = {},
    }
    function state.tick(key, item, ticked, note)
        local ok, done = pcall(options.tick, key, item, ticked, note)
        return ok and done ~= false
    end
    function state.toggle(key)
        pcall(options.toggle, key)
    end
    function state.redraw()
        pcall(options.redraw)
    end
    return state
end

local function noteId(row)
    return tostring(row.key) .. "\31" .. tostring(row.item)
end

local function showTooltip(state, owner, tooltip)
    local game = state.tooltip
    if tooltip ~= nil and game ~= nil then
        game:SetOwner(owner, "ANCHOR_RIGHT")
        local index
        for index = 1, #tooltip do
            game:AddLine(tooltip[index], 1, 1, 1, true)
        end
        game:Show()
    end
end

-- Ticks an officer's needs-a-note item with the note typed under it, or,
-- with none typed yet, asks for one.
local function tickWithNote(state, row)
    local id = noteId(row)
    local note = state.notes[id]
    if note == nil or string.find(note, "%S") == nil then
        state.noteNeeded[id] = true
        state.redraw()
        return
    end
    if state.tick(row.key, row.item, true, note) then
        state.notes[id] = nil
        state.noteNeeded[id] = nil
    end
end

-- Gives `line` (a frame with a `text` font string) its check box, note
-- box and button, hidden until Draw needs them, and makes a character's
-- line open or close its checklist when clicked.
function PromotionLines.Attach(line, state)
    local function hideTooltip()
        if state.tooltip ~= nil then
            state.tooltip:Hide()
        end
    end
    line.check = state.createFrame("CheckButton", nil, line, "UICheckButtonTemplate")
    line.check:SetSize(20, 20)
    line.check:SetPoint("LEFT", line, "LEFT", 14, 0)
    line.check:SetScript("OnClick", function(self)
        local row = line.row
        if row == nil or not row.canCheck then
            self:SetChecked(row ~= nil and row.checked)
            return
        end
        -- The box shows the item's state until the change is saved.
        self:SetChecked(row.checked)
        if not row.ticked and row.needsNote then
            tickWithNote(state, row)
            return
        end
        -- Unticked, the note stays in its box, ready to tick again (set
        -- first: the untick redraws the list).
        local id = noteId(row)
        local typed = state.notes[id]
        if row.ticked and row.note ~= nil then
            state.notes[id] = row.note
        end
        if not state.tick(row.key, row.item, not row.ticked) then
            state.notes[id] = typed
        end
    end)
    line.check:SetScript("OnEnter", function(self)
        showTooltip(state, self, line.row and line.row.tooltip)
    end)
    line.check:SetScript("OnLeave", hideTooltip)
    line.check:Hide()
    -- A needs-a-note item's note: Enter ticks the item with the note typed,
    -- or saves a ticked item's changed note. A failed check's line takes an
    -- override's optional reason instead: Enter overrides with it.
    line.noteLabel = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    line.noteLabel:SetPoint("LEFT", line, "LEFT", 40, 0)
    line.noteLabel:Hide()
    line.note = state.createFrame("EditBox", nil, line, "InputBoxTemplate")
    line.note:SetHeight(18)
    line.note:SetPoint("LEFT", line.noteLabel, "RIGHT", 8, 0)
    line.note:SetPoint("RIGHT", line, "RIGHT", -8, 0)
    line.note:SetAutoFocus(false)
    line.note:SetMaxLetters(addon.PromotionChecks.MAX_NOTE)
    line.note.placeholder = line.note:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    line.note.placeholder:SetPoint("LEFT", line.note, "LEFT", 2, 0)
    line.note:SetScript("OnTextChanged", function(self, userInput)
        local row = line.row
        if row == nil or not row.noteInput then
            return
        end
        local text = self:GetText()
        if userInput then
            state.notes[noteId(row)] = text
        end
        if text == "" then
            self.placeholder:Show()
        else
            self.placeholder:Hide()
        end
    end)
    line.note:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        local row = line.row
        if row == nil or not row.noteInput then
            return
        end
        if row.reason then
            local id = noteId(row)
            if state.tick(row.key, row.item, true, state.notes[id]) then
                state.notes[id] = nil
            end
        elseif not (row.ticked and self:GetText() == (row.note or "")) then
            tickWithNote(state, row)
        end
    end)
    line.note:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    line.note:Hide()
    -- An automated item's button: Override (with the reason typed on the
    -- line below, if any) and Undo override.
    line.act = state.createFrame("Button", nil, line, "UIPanelButtonTemplate")
    line.act:SetSize(96, 18)
    line.act:SetPoint("RIGHT", line, "RIGHT", -2, 0)
    line.act:SetScript("OnClick", function()
        local row = line.row
        if row == nil or row.kind ~= "promotion" then
            return
        end
        if row.ticked then
            state.tick(row.key, row.item, false)
            return
        end
        local id = noteId(row)
        if state.tick(row.key, row.item, true, state.notes[id]) then
            state.notes[id] = nil
        end
    end)
    line.act:SetScript("OnEnter", function(self)
        showTooltip(state, self, line.row and line.row.tooltip)
    end)
    line.act:SetScript("OnLeave", hideTooltip)
    line.act:Hide()
    line:EnableMouse(true)
    line:SetScript("OnMouseUp", function()
        local row = line.row
        if row ~= nil and row.toggle then
            state.toggle(row.key)
        end
    end)
end

-- Hides what Attach gave `line`, for a row that isn't a Promotion row.
function PromotionLines.Hide(line)
    line.check:Hide()
    if line.note:HasFocus() then
        line.note:ClearFocus()
    end
    line.noteLabel:Hide()
    line.note:Hide()
    line.act:Hide()
end

-- Draws Promotion row `row` on `line`: its text (after its check box for
-- an item), and the check box, note box and button it has.
function PromotionLines.Draw(line, row, state)
    line.row = row
    local acts = row.action ~= nil
    line.text:ClearAllPoints()
    if row.check then
        line.text:SetPoint("LEFT", line.check, "RIGHT", 2, 0)
    else
        line.text:SetPoint("LEFT", line, "LEFT", 6, 0)
    end
    line.text:SetPoint("RIGHT", line, "RIGHT", acts and -100 or -6, 0)
    line.text:SetText(row.noteInput and "" or ((row.check and "" or "  ") .. tostring(row.text or "")))
    if row.check then
        line.check:SetChecked(row.checked == true)
        if row.canCheck then
            line.check:Enable()
        else
            line.check:Disable()
        end
        line.check:Show()
    else
        line.check:Hide()
    end
    if row.noteInput then
        local id = noteId(row)
        if not line.note:HasFocus() then
            line.note:SetText(state.notes[id] or row.note or "")
        end
        line.noteLabel:SetText(row.reason and "Reason:" or "Note:")
        if row.reason then
            line.note.placeholder:SetText("Optional, then Override (or Enter)")
        else
            line.note.placeholder:SetText(state.noteNeeded[id]
                and "|cffff8040Type a note, then tick the box|r" or "Note (needed to tick it)")
        end
        if line.note:GetText() == "" then
            line.note.placeholder:Show()
        else
            line.note.placeholder:Hide()
        end
        line.noteLabel:Show()
        line.note:Show()
    else
        if line.note:HasFocus() then
            line.note:ClearFocus()
        end
        line.noteLabel:Hide()
        line.note:Hide()
    end
    if acts then
        line.act:SetText(row.action)
        line.act:Show()
    else
        line.act:Hide()
    end
end
