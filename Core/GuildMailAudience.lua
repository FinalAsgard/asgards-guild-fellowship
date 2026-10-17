local _, addon = ...

-- Decides who gets a Guild Mail: one mail per player, to their main, when
-- that main's own rank is one of the ticked ranks. Every player with a
-- character in the guild has an in-guild main (a lone character is its own
-- main), so nobody unorganized drops out. Departed characters are never
-- mailed, and neither is any character of the sender's own player.
--
-- Pure: it reads a FellowshipStore partition and never touches the game.
local GuildMailAudience = {}
addon.GuildMailAudience = GuildMailAudience

local function sortName(recipient)
    return string.lower(recipient.name)
end

-- The recipients, sorted by rank (highest rank first, as the game numbers
-- them from 0) and then by name. Each is
--   { key, playerId, name, rank }
-- where `name` is the character's name as the roster spells it, which is
-- what the mail is addressed to.
--
-- options:
--   ranks    set of 0-based rank indexes ({ [2] = true, [4] = true })
--   selfKey  the sender's character key, or nil
function GuildMailAudience.Recipients(partition, options)
    options = options or {}
    local ranks = options.ranks or {}
    local sender = options.selfKey and partition:GetCharacter(options.selfKey)
    local own = sender and sender.player

    local recipients = {}
    partition:EachPlayer(function(id, player)
        if id == own then
            return
        end
        local key = player.main
        local character = key and partition:GetCharacter(key)
        if character == nil or not partition:IsInGuild(key) then
            return
        end
        if type(character.rank) ~= "number" or not ranks[character.rank] then
            return
        end
        table.insert(recipients, {
            key = key,
            playerId = id,
            name = character.name or key,
            rank = character.rank,
        })
    end)

    table.sort(recipients, function(first, second)
        if first.rank ~= second.rank then
            return first.rank < second.rank
        end
        local firstName, secondName = sortName(first), sortName(second)
        if firstName ~= secondName then
            return firstName < secondName
        end
        return first.key < second.key
    end)
    return recipients
end
