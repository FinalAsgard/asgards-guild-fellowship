local _, addon = ...

-- Classifies the running WoW client. Each supported manifest declares its
-- target client in `## X-Client`, and each client loads its own manifest
-- (Forever prefers `_Camelot` over `_Mainline`); runtime project constants then
-- confirm a Retail declaration. Shared or similar client internals alone never
-- classify a client.
local ClientProfile = {
    MANIFEST_FIELD = "X-Client",
}
addon.ClientProfile = ClientProfile

-- `twoPartNames`: Forever character names are "First Last"; Retail names are
-- a single word. NameNormalizer receives this instead of detecting it.
local function supported(id, label, twoPartNames)
    return {
        id = id,
        label = label,
        nameRules = { twoPartNames = twoPartNames },
        supported = true,
    }
end

local function unsupported(reason)
    return {
        id = "unsupported",
        label = "Unsupported client",
        reason = reason,
        supported = false,
    }
end

-- Reads one manifest field through whichever metadata API the client has.
-- Returns nil when the API is missing, raises, or the field is not a string.
function ClientProfile.ReadMetadata(environment, addonName, field)
    local addOns = environment.C_AddOns
    local getMetadata = type(addOns) == "table" and addOns.GetAddOnMetadata
    if type(getMetadata) ~= "function" then
        getMetadata = environment.GetAddOnMetadata
    end
    if type(getMetadata) ~= "function" then
        return nil
    end

    local ok, value = pcall(getMetadata, addonName, field)
    if not ok or type(value) ~= "string" then
        return nil
    end

    return value
end

local function isMainlineProject(environment)
    local projectId = environment.WOW_PROJECT_ID
    return projectId ~= nil and projectId == environment.WOW_PROJECT_MAINLINE
end

function ClientProfile.Detect(environment, addonName)
    local declared = ClientProfile.ReadMetadata(environment, addonName, ClientProfile.MANIFEST_FIELD)
    if declared == nil then
        return unsupported("the add-on manifest does not declare a supported client")
    end

    if declared == "Forever" then
        return supported("forever", "WoW Forever", true)
    end

    if declared == "Retail" then
        if isMainlineProject(environment) then
            return supported("retail", "WoW Retail", false)
        end
        return unsupported("the Retail manifest loaded on a non-Retail client")
    end

    return unsupported("the add-on manifest declares unknown client '" .. declared .. "'")
end
