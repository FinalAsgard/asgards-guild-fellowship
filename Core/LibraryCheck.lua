local _, addon = ...

-- Verifies at load that each required library registered itself, so a missing
-- or broken library becomes one clear message instead of Lua errors later.
-- REQUIRED must match tools/libraries.txt (checked by the specs).
local LibraryCheck = {
    REQUIRED = {
        { name = "LibStub", major = "LibStub" },
        { name = "CallbackHandler-1.0", major = "CallbackHandler-1.0" },
        { name = "LibDataBroker-1.1", major = "LibDataBroker-1.1" },
        { name = "LibDBIcon-1.0", major = "LibDBIcon-1.0" },
        { name = "LibSharedMedia-3.0", major = "LibSharedMedia-3.0" },
        -- The framework registers with LibStub and sets its global first, then
        -- loads the rest of its core file. `FrameWorkVersion` is set late in
        -- that file, so it shows the framework loaded rather than failed
        -- partway (as it may on WoW Forever).
        {
            name = "Details! Framework",
            major = "DetailsFramework-1.0",
            global = "DetailsFramework",
            loadedField = "FrameWorkVersion",
        },
        { name = "AceSerializer-3.0", major = "AceSerializer-3.0" },
        { name = "AceComm-3.0", major = "AceComm-3.0" },
    },
}
addon.LibraryCheck = LibraryCheck

local Checker = {}
Checker.__index = Checker

local function isPresent(client, library)
    if library.major == "LibStub" then
        return client:HasLibStub()
    end

    if client:GetLibrary(library.major) == nil then
        return false
    end

    if library.global ~= nil then
        local value = client:GetGlobal(library.global)
        if type(value) ~= "table" then
            return false
        end
        if library.loadedField ~= nil and value[library.loadedField] == nil then
            return false
        end
    end

    return true
end

function LibraryCheck.Create(client)
    return setmetatable({ client = client }, Checker)
end

-- Checks every required library once; later calls return the same result.
function Checker:Run()
    if self.present == nil then
        self.present, self.missing = {}, {}
        local index
        for index = 1, #LibraryCheck.REQUIRED do
            local library = LibraryCheck.REQUIRED[index]
            if isPresent(self.client, library) then
                table.insert(self.present, library.name)
            else
                table.insert(self.missing, library.name)
            end
        end
    end

    return self.present, self.missing
end

-- The one message printed at load when libraries are missing, or nil.
function Checker:MissingMessage()
    local _, missing = self:Run()
    if #missing == 0 then
        return nil
    end

    return addon.Identity.chatPrefix .. " Missing libraries: " .. table.concat(missing, ", ") ..
        ". Reinstall the add-on, or in a development checkout run tools/Fetch-Libraries.ps1."
end

-- The library line of `help`.
function Checker:Summary()
    local present, missing = self:Run()
    if #missing == 0 then
        return addon.Identity.chatPrefix .. " Libraries: all " .. #present .. " present."
    end

    local presentText = #present > 0 and table.concat(present, ", ") or "none"
    return addon.Identity.chatPrefix .. " Libraries present: " .. presentText ..
        ". Missing: " .. table.concat(missing, ", ") .. "."
end
