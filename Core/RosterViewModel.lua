local _, addon = ...

-- How the roster words time and the guild's size: last online, "Synced 5
-- minutes ago", "Left 3 days ago", and the counts the Guild Roster's
-- tooltip shows. Pure: the caller passes in everything it needs.
local RosterViewModel = {}
addon.RosterViewModel = RosterViewModel

local function plural(count, unit)
    return count .. " " .. unit .. (count == 1 and "" or "s")
end

-- "3 days ago" from the roster's { years, months, days, hours } offline
-- time, using its largest non-zero unit. Nil when unknown.
function RosterViewModel.FormatLastOnline(lastOnline)
    if type(lastOnline) ~= "table" then
        return nil
    end
    local units = {
        { field = "years", name = "year" },
        { field = "months", name = "month" },
        { field = "days", name = "day" },
        { field = "hours", name = "hour" },
    }
    local index
    for index = 1, #units do
        local count = lastOnline[units[index].field]
        if type(count) == "number" and count > 0 then
            return plural(count, units[index].name) .. " ago"
        end
    end
    return "less than an hour ago"
end

-- "just now", "5 minutes ago", "2 hours ago" or "3 days ago" for
-- `elapsed` seconds, using its largest unit.
function RosterViewModel.Ago(elapsed)
    if elapsed < 60 then
        return "just now"
    elseif elapsed < 3600 then
        return plural(math.floor(elapsed / 60), "minute") .. " ago"
    elseif elapsed < 86400 then
        return plural(math.floor(elapsed / 3600), "hour") .. " ago"
    end
    return plural(math.floor(elapsed / 86400), "day") .. " ago"
end

-- The footer's sync line: "Synced 5 minutes ago", or "Not synced yet".
function RosterViewModel.SyncText(lastSync, now)
    if type(lastSync) ~= "number" then
        return "Not synced yet"
    end
    return "Synced " .. RosterViewModel.Ago(math.max(0, (now or lastSync) - lastSync))
end

-- What `/agf sync` prints, one line each, from SyncSession's status (nil
-- without a guild).
function RosterViewModel.SyncStatusLines(status, now)
    if status == nil then
        return { "Guild sync isn't available: you're not in a guild, or saved data isn't ready." }
    end
    if not status.on then
        return { "Guild sync is off: the libraries it needs are missing." }
    end
    local state = "Guild sync is running."
    if status.paused then
        state = "Guild sync is paused while you're in combat, a boss encounter or a keystone run."
    end
    local lines = { state .. " " .. RosterViewModel.SyncText(status.lastSync, now) .. "." }
    if status.pending ~= nil then
        if status.pending == 0 then
            table.insert(lines, "None of your suggestions are waiting for an officer.")
        else
            table.insert(lines, plural(status.pending, "suggestion") .. " of yours "
                .. (status.pending == 1 and "is" or "are") .. " waiting for an officer.")
        end
    end
    return lines
end

-- "Left 3 days ago" for a departed character, from its departure date.
function RosterViewModel.LeftText(departed, now)
    local elapsed = math.max(0, (now or departed) - departed)
    local days = math.floor(elapsed / 86400)
    if days < 1 then
        return "Left today"
    end
    return "Left " .. plural(days, "day") .. " ago"
end
-- The windows, in days, players are counted active within.
RosterViewModel.ACTIVE_DAYS = { 7, 30, 90 }

-- Hours since a character was last online, from the roster's { years,
-- months, days, hours } (a month taken as 30 days), or nil when unknown.
function RosterViewModel.HoursAway(lastOnline)
    if type(lastOnline) ~= "table" then
        return nil
    end
    local months = (lastOnline.years or 0) * 12 + (lastOnline.months or 0)
    return (months * 30 + (lastOnline.days or 0)) * 24 + (lastOnline.hours or 0)
end
local hoursAway = RosterViewModel.HoursAway

-- How big the guild is, from every player's current characters (departed
-- ones never count), whatever the roster's search and filters:
--   { known, unlinked, players, alts, characters, playersOnline,
--     charactersOnline, withAlias, declared, active = { [days] = n } }
-- A player is known when they have two or more current characters, an
-- alias, or a current main that was declared; otherwise their one character
-- is unlinked, and counts as a player of its own until it's linked.
-- players = known + unlinked. Alts are each known player's characters after
-- the first, so players + alts == characters. `members` (live roster facts
-- keyed by character key) says who is online and when each character was
-- last online: playersOnline counts players with a character online, and
-- active[days] players with one online within that many days (see
-- ACTIVE_DAYS). withAlias and declared count players with an alias, and
-- with a declared current main.
function RosterViewModel.Counts(partition, members)
    members = members or {}
    local counts = {
        known = 0, unlinked = 0, players = 0, alts = 0, characters = 0,
        playersOnline = 0, charactersOnline = 0, withAlias = 0, declared = 0, active = {},
    }
    local index
    for index = 1, #RosterViewModel.ACTIVE_DAYS do
        counts.active[RosterViewModel.ACTIVE_DAYS[index]] = 0
    end
    partition:EachPlayer(function(id, player)
        local keys = partition:CharactersOf(id)
        local current, online = 0, 0
        -- Hours since the player's most recent login; 0 while online.
        local latest
        local keyIndex
        for keyIndex = 1, #keys do
            if partition:IsInGuild(keys[keyIndex]) then
                current = current + 1
                local live = members[keys[keyIndex]]
                local away
                if live ~= nil and live.online == true then
                    online = online + 1
                    away = 0
                else
                    away = hoursAway(live and live.lastOnline)
                end
                if away ~= nil and (latest == nil or away < latest) then
                    latest = away
                end
            end
        end
        if current == 0 then
            return
        end
        counts.players = counts.players + 1
        counts.characters = counts.characters + current
        counts.charactersOnline = counts.charactersOnline + online
        counts.playersOnline = counts.playersOnline + (online > 0 and 1 or 0)
        local days
        for days in pairs(counts.active) do
            if latest ~= nil and latest < days * 24 then
                counts.active[days] = counts.active[days] + 1
            end
        end
        local declared = player.main ~= nil and partition:IsInGuild(player.main) and partition:IsDeclared(player.main)
        if current >= 2 or player.alias ~= nil or declared then
            counts.known = counts.known + 1
            counts.alts = counts.alts + current - 1
            counts.withAlias = counts.withAlias + (player.alias ~= nil and 1 or 0)
            counts.declared = counts.declared + (declared and 1 or 0)
        else
            counts.unlinked = counts.unlinked + 1
        end
    end)
    return counts
end

-- The guild's counts as the Guild Roster's tooltip shows them, one string
-- per line: a "Guild size" title,
-- the players and how many are known, who is active and online, how
-- complete the Fellowship data is, and (when there are any) what
-- "unlinked" means.
function RosterViewModel.CountsTooltip(counts)
    local lines = { "Guild size" }
    if counts.unlinked > 0 then
        table.insert(lines, plural(counts.players, "player") .. ": " .. counts.known .. " known + "
            .. counts.unlinked .. " unlinked")
    else
        table.insert(lines, plural(counts.players, "player") .. ", all known")
    end
    local active = {}
    local index
    for index = 1, #RosterViewModel.ACTIVE_DAYS do
        local days = RosterViewModel.ACTIVE_DAYS[index]
        table.insert(active, (counts.active and counts.active[days] or 0) .. " in " .. days .. " days")
    end
    table.insert(lines, "Active players: " .. table.concat(active, ", "))
    table.insert(lines, counts.playersOnline .. " of " .. plural(counts.players, "player") .. " online")
    table.insert(lines, counts.charactersOnline .. " of " .. plural(counts.characters, "character") .. " online")
    table.insert(lines, plural(counts.withAlias, "player") .. " " .. (counts.withAlias == 1 and "has" or "have")
        .. " an alias")
    table.insert(lines, plural(counts.declared, "main") .. " declared")
    if counts.unlinked > 0 then
        table.insert(lines, "  Unlinked: a lone character with no alias or declared main.")
        table.insert(lines, "  It counts as a player until it's linked, but may be someone's alt.")
    end
    return lines
end
