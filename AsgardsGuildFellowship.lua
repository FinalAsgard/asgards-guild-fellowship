local _, addon = ...

-- Composition root: builds the modules in order. Besides the adapter, this is
-- the only place that consults the client profile.
local client = addon.Compatibility.Create()
local clientProfile = client:GetClientProfile()
local version = client:GetAddOnMetadata("Version") or "unknown"
local router = addon.CommandRouter.Create(function(message)
    client:Print(message)
end)

local libraryCheck = addon.LibraryCheck.Create(client)

router:Register("help", "show available commands", function()
    router:PrintHelp()
    client:Print(addon.Identity.chatPrefix .. " Version " .. version ..
        " on " .. clientProfile.label .. ".")
    client:Print(libraryCheck:Summary())
end)

-- Libraries load before this file, so they are checked now. The router still
-- starts, so `help` works with libraries missing.
local missingLibraries = libraryCheck:MissingMessage()
if missingLibraries ~= nil then
    client:Print(missingLibraries)
end

local persistence
if clientProfile.supported then
    persistence = addon.Persistence.Create(client)
else
    -- Never touch saved data on a client we cannot identify.
    client:Print(addon.Identity.chatPrefix .. " This game client is not supported (" ..
        clientProfile.reason .. "). Supported clients are WoW Forever and WoW Retail. " ..
        "Saved data was left unchanged.")
end

local lifecycle = addon.Lifecycle.Create(client, router, persistence)

addon.client = client
addon.clientProfile = clientProfile
addon.libraryCheck = libraryCheck
addon.lifecycle = lifecycle
addon.persistence = persistence
addon.router = router
addon.version = version

lifecycle:Start()
