local _, addon = ...

-- Decides who gets a Guild Mail. A character is a candidate when it's in the
-- guild and its own rank is one of the ticked ranks; the Send to mode then
-- picks from each player's candidates:
--   mains   the player's main, when the main is a candidate. Every player
--           with a character in the guild has an in-guild main (a lone
--           character is its own main), so nobody unorganized drops out.
--   recent  the candidate online most recently (online now counts as most
--           recent), one per player
--   all     every candidate
-- Departed characters are never mailed, and neither is any character of the
-- sender's own player. Two filters can drop more, before the mode picks:
-- every character of a player with a Discord name on file, and characters
-- not online within the last N days.
--
-- Pure: it reads a FellowshipStore partition and the live roster facts it's
-- given, and never touches the game.
local GuildMailAudience = {
    MAINS = "mains",
    RECENT = "recent",
    ALL = "all",
}
addon.GuildMailAudience = GuildMailAudience

-- Characters missing from the live roster sort after everyone with a known
-- last-online time.
local UNKNOWN_HOURS = math.huge

local function sortName(recipient)
    return string.lower(recipient.name)
end

local function byName(first, second)
    local firstName, secondName = sortName(first), sortName(second)
    if firstName ~= secondName then
        return firstName < secondName
    end
    return first.key < second.key
end

-- Hours since the character was last online: 0 while online, nil when the
-- live roster doesn't say.
local function hoursAway(member)
    if member == nil then
        return nil
    end
    if member.online then
        return 0
    end
    return addon.GuildGreet.HoursAway(member.lastOnline)
end

-- The recipients, sorted by rank (highest rank first, as the game numbers
-- them from 0) and then by name. Each is
--   { key, playerId, name, playerName, rank, online, lastOnline, hoursAway }
-- where `name` is the character's name as the roster spells it, which is
-- what the mail is addressed to, and `playerName` is the player's alias or
-- their main's name.
--
-- options:
--   ranks    set of 0-based rank indexes ({ [2] = true, [4] = true })
--   mode     "mains" (the default), "recent" or "all"
--   live     live roster facts by character key ({ online, lastOnline }),
--            for the last-online times
--   selfKey  the sender's character key, or nil
--   skipDiscord  true to leave out players with a Discord name on file
--   activeDays   when set, only characters online now or within this many
--                days count; one the live roster doesn't know doesn't
function GuildMailAudience.Recipients(partition, options)
    options = options or {}
    local ranks = options.ranks or {}
    local mode = options.mode or GuildMailAudience.MAINS
    local live = options.live or {}
    local sender = options.selfKey and partition:GetCharacter(options.selfKey)
    local own = sender and sender.player
    local activeHours = type(options.activeDays) == "number" and options.activeDays * 24 or nil

    local recipients = {}
    partition:EachPlayer(function(id, player)
        if id == own then
            return
        end
        if options.skipDiscord then
            local discord = partition:PlayerProfileText(id, "discord")
            if type(discord) == "string" and string.match(discord, "%S") then
                return
            end
        end
        local main = player.main and partition:GetCharacter(player.main)
        local playerName = player.alias or (main and main.name) or player.main
        local candidates = {}
        local keys = partition:CharactersOf(id)
        local index
        for index = 1, #keys do
            local key = keys[index]
            local character = partition:GetCharacter(key)
            local member = live[key]
            local away = hoursAway(member)
            if partition:IsInGuild(key) and type(character.rank) == "number" and ranks[character.rank]
                and (mode ~= GuildMailAudience.MAINS or key == player.main)
                and (activeHours == nil or (away ~= nil and away <= activeHours))
            then
                table.insert(candidates, {
                    key = key,
                    playerId = id,
                    name = character.name or key,
                    playerName = playerName,
                    rank = character.rank,
                    online = member ~= nil and member.online == true,
                    lastOnline = member and member.lastOnline,
                    hoursAway = away,
                })
            end
        end
        if mode == GuildMailAudience.RECENT and #candidates > 1 then
            table.sort(candidates, function(first, second)
                local firstHours = first.hoursAway or UNKNOWN_HOURS
                local secondHours = second.hoursAway or UNKNOWN_HOURS
                if firstHours ~= secondHours then
                    return firstHours < secondHours
                end
                return byName(first, second)
            end)
            candidates = { candidates[1] }
        end
        for index = 1, #candidates do
            table.insert(recipients, candidates[index])
        end
    end)

    table.sort(recipients, function(first, second)
        if first.rank ~= second.rank then
            return first.rank < second.rank
        end
        return byName(first, second)
    end)
    return recipients
end
