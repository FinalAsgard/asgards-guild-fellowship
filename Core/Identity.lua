local addonName, addon = ...

-- The only place production and development names differ. Every other module
-- reads the current build's names from `addon.Identity`.
local VARIANTS = {
    AsgardsGuildFellowship = {
        displayName = "Asgard's Guild Fellowship",
        shortName = "Guild Fellowship",
        slashAlias = "/asgardsfellowship",
        slashCommand = "/agf",
    },
    AsgardsGuildFellowshipDev = {
        displayName = "Asgard's Guild Fellowship (Dev)",
        shortName = "Guild Fellowship (Dev)",
        isDevelopment = true,
        slashAlias = "/asgardsfellowshipdev",
        slashCommand = "/agfdev",
    },
}

local variant = VARIANTS[addonName]
if variant == nil then
    error("unsupported Asgard's Guild Fellowship add-on identity: " .. tostring(addonName))
end

addon.Identity = {
    addonName = addonName,
    databaseName = addonName .. "DB",
    displayName = variant.displayName,
    shortName = variant.shortName,
    -- Starts every chat message: the short name in the add-on's gold.
    chatPrefix = "|cffd4af37[" .. variant.shortName .. "]|r",
    isDevelopment = variant.isDevelopment == true,
    slashAlias = variant.slashAlias,
    slashCommand = variant.slashCommand,
    slashKey = string.upper(string.sub(variant.slashCommand, 2)),
}
