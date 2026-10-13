-- A stand-in for the game's frames, for specs that draw settings: every
-- method does nothing, except that text set on a font string is recorded on
-- the page it belongs to, so a spec can read what each options page shows.
-- Pages are the plain frames made with no parent; a frame made inside a page
-- (a scroll area, a row) records into that same page. Check boxes keep
-- their checked state, frames their width and height, and scripts and
-- hooked scripts are kept by name.
local FakeFrames = {}

-- Gives `environment` a CreateFrame drawing such frames, and
-- `environment.pages`, the pages in the order they were made. Setting
-- `environment.editBoxFails` to a set of method names makes those methods
-- raise on text boxes, as on a client that lacks them. Returns
-- `environment`.
function FakeFrames.install(environment)
    environment.pages = {}
    local function widget(page)
        local object = { shown = true, page = page }
        return setmetatable(object, {
            __index = function(_, method)
                if method == "SetText" then
                    return function(self, text)
                        self.text = text
                        local texts = type(page) == "table" and rawget(page, "texts")
                        if texts then
                            table.insert(texts, text)
                        end
                    end
                elseif method == "Show" then
                    return function(self)
                        self.shown = true
                    end
                elseif method == "Hide" then
                    return function(self)
                        self.shown = false
                    end
                elseif method == "CreateFontString" or method == "CreateTexture" then
                    return function()
                        return widget(page)
                    end
                elseif method == "HasFocus" then
                    return function()
                        return false
                    end
                elseif method == "SetChecked" then
                    return function(self, checked)
                        rawset(self, "checked", checked)
                    end
                elseif method == "GetChecked" then
                    return function(self)
                        return rawget(self, "checked") == true
                    end
                elseif method == "SetHeight" then
                    return function(self, height)
                        rawset(self, "height", height)
                    end
                elseif method == "SetScript" then
                    return function(self, name, handler)
                        rawset(self, "scripts", rawget(self, "scripts") or {})
                        self.scripts[name] = handler
                    end
                elseif method == "HookScript" then
                    return function(self, name, handler)
                        rawset(self, "hooks", rawget(self, "hooks") or {})
                        self.hooks[name] = handler
                    end
                elseif method == "SetWidth" then
                    return function(self, width)
                        rawset(self, "width", width)
                    end
                elseif method == "SetCursorPosition" then
                    return function(self, position)
                        rawset(self, "cursor", position)
                    end
                elseif method == "SetMultiLine" then
                    return function(self, multiLine)
                        rawset(self, "multiLine", multiLine)
                    end
                elseif method == "GetText" then
                    -- Like a real text box, an empty one gives "".
                    return function(self)
                        return rawget(self, "text") or ""
                    end
                end
                return function() end
            end,
        })
    end
    environment.CreateFrame = function(frameType, _, parent)
        local owner = parent and (rawget(parent, "texts") ~= nil and parent or rawget(parent, "page"))
        if frameType == "EditBox" and environment.editBoxFails ~= nil then
            local box = widget(owner)
            local name
            for name in pairs(environment.editBoxFails) do
                rawset(box, name, function()
                    error("no " .. name .. " on this client")
                end)
            end
            return box
        end
        if parent == nil then
            local page = widget(nil)
            page.texts = {}
            -- A page's own font strings record into it.
            getmetatable(page).__index = (function(original)
                return function(self, method)
                    if method == "CreateFontString" or method == "CreateTexture" then
                        return function()
                            return widget(self)
                        end
                    end
                    return original(self, method)
                end
            end)(getmetatable(page).__index)
            table.insert(environment.pages, page)
            return page
        end
        return widget(owner)
    end
    return environment
end

-- A master frame tab's content frame, as the Group Finder draws on: a page
-- that knows whether it's shown (IsShown), with its hooked scripts kept.
function FakeFrames.host(environment)
    local host = environment.CreateFrame("Frame", nil, nil)
    rawset(host, "IsShown", function(self)
        return self.shown
    end)
    return host
end

-- Whether `list` holds `value`.
function FakeFrames.contains(list, value)
    local index
    for index = 1, #list do
        if list[index] == value then
            return true
        end
    end
    return false
end

return FakeFrames
