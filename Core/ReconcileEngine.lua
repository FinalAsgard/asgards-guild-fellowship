local _, addon = ...

-- Compares a roster snapshot (with note text) against a guild partition and
-- plans the changes. Plan() never mutates anything; Apply() commits a plan.
--
-- This slice implements seeding: a note marker on a character with no
-- relationship in the database is applied directly, which covers the whole
-- first scan. Markers that can't be applied (unresolved, ambiguous, cyclic,
-- self-referencing, or competing aliases) are left unapplied and recorded
-- for the conflict queue. Drift conflicts, departures, and out-of-guild
-- mains come in later slices.
local ReconcileEngine = {
    MAX_CHAIN_DEPTH = 10,
}
addon.ReconcileEngine = ReconcileEngine

-- Matches marker text against roster characters: a full name (with or
-- without realm), or on Forever a single word as a unique first name.
local function newResolver(members, normalizer, twoPartNames)
    local byFirstName = {}
    if twoPartNames then
        local key, member
        for key, member in pairs(members) do
            local first = normalizer:FirstName(member.name)
            if first ~= nil then
                byFirstName[first] = byFirstName[first] or {}
                table.insert(byFirstName[first], key)
            end
        end
        local _, keys
        for _, keys in pairs(byFirstName) do
            table.sort(keys)
        end
    end

    return function(text)
        local key = normalizer:Key(text)
        if key ~= nil and members[key] ~= nil then
            return { key }
        end
        if twoPartNames and string.find(text, "[%s%-]") == nil then
            return byFirstName[normalizer:FirstName(text)] or {}
        end
        return {}
    end
end

-- How many characters belong to each player in the partition.
local function playerSizes(partition)
    local sizes = {}
    partition:EachCharacter(function(_, character)
        sizes[character.player] = (sizes[character.player] or 0) + 1
    end)
    return sizes
end

-- A character with no relationship is unknown, or the only character, main,
-- and unnamed member of its own player. Only those are seeded from notes.
local function hasRelationship(partition, sizes, key)
    local character = partition:GetCharacter(key)
    if character == nil then
        return false
    end
    local player = partition:GetPlayer(character.player)
    return player == nil
        or player.main ~= key
        or player.alias ~= nil
        or (sizes[character.player] or 0) > 1
end

-- The main a resolved marker ultimately leads to, following other notes
-- (A>B, B>C gives C). A character that is already organized stops the
-- chain at its player's main. Returns nil and a reason when it can't be
-- followed.
local function followChain(start, target, parses, partition, sizes)
    local visited = { [start] = true }
    local current = target
    local depth = 0
    while true do
        if visited[current] then
            return nil, "cycle"
        end
        visited[current] = true

        if hasRelationship(partition, sizes, current) then
            local player = partition:GetPlayer(partition:GetCharacter(current).player)
            return player and player.main or current
        end

        local parse = parses[current]
        local nextRef = parse and parse.mainRef
        if nextRef == nil or nextRef.status ~= "resolved" or nextRef.key == current then
            return current
        end
        depth = depth + 1
        if depth > ReconcileEngine.MAX_CHAIN_DEPTH then
            return nil, "chain too long"
        end
        current = nextRef.key
    end
end

local function addUnapplied(plan, key, reason)
    table.insert(plan.unapplied, {
        character = key,
        fingerprint = plan.fingerprints[key],
        reason = reason,
    })
end

-- inputs: partition, members (key -> roster facts with `note`), normalizer,
-- rules (client name rules), mode ("initial", "full", or "incremental").
-- Returns a plan:
--   members      key -> roster facts to record
--   fingerprints key -> note fingerprint (never the note text)
--   links        alt key -> the main key whose player it joins
--   aliases      main key -> alias for that main's player
--   unapplied    { character, fingerprint, reason } for the conflict queue
function ReconcileEngine.Plan(inputs)
    local partition = inputs.partition
    local members = inputs.members or {}
    local rules = inputs.rules or {}
    local resolver = newResolver(members, inputs.normalizer, rules.twoPartNames == true)
    local sizes = playerSizes(partition)
    local plan = {
        aliases = {},
        fingerprints = {},
        links = {},
        members = members,
        mode = inputs.mode or "initial",
        unapplied = {},
    }

    local parses = {}
    local keys = {}
    local key, member
    for key, member in pairs(members) do
        table.insert(keys, key)
        plan.fingerprints[key] = addon.NoteParser.Fingerprint(member.note or "")
        parses[key] = addon.NoteParser.Parse(member.note, resolver, rules)
    end
    -- Plans are deterministic whatever order the roster comes in.
    table.sort(keys)

    local seedable = {}
    local index
    for index = 1, #keys do
        key = keys[index]
        seedable[key] = not hasRelationship(partition, sizes, key)
    end

    for index = 1, #keys do
        key = keys[index]
        local ref = parses[key].mainRef
        if seedable[key] and ref ~= nil then
            if ref.status ~= "resolved" then
                addUnapplied(plan, key, ref.status)
            elseif ref.key == key then
                addUnapplied(plan, key, "self reference")
            else
                local root, reason = followChain(key, ref.key, parses, partition, sizes)
                if root == nil then
                    addUnapplied(plan, key, reason)
                elseif root ~= key then
                    plan.links[key] = root
                end
            end
        end
    end

    -- An alias on any character's note names that character's player.
    local proposals = {}
    for index = 1, #keys do
        key = keys[index]
        local alias = parses[key].alias
        if seedable[key] and alias ~= nil then
            local root = plan.links[key] or key
            proposals[root] = proposals[root] or {}
            table.insert(proposals[root], { alias = alias, character = key })
        end
    end
    local root, entries
    for root, entries in pairs(proposals) do
        local agreed = entries[1].alias
        local folded = string.lower(agreed)
        for index = 2, #entries do
            if string.lower(entries[index].alias) ~= folded then
                agreed = nil
                break
            end
        end
        if agreed == nil then
            for index = 1, #entries do
                addUnapplied(plan, entries[index].character, "competing aliases")
            end
        elseif not seedable[root] and partition:GetCharacter(root) ~= nil then
            -- The main's player is already organized; the conflict queue
            -- decides whether a note may rename it.
            for index = 1, #entries do
                addUnapplied(plan, entries[index].character, "player already organized")
            end
        else
            plan.aliases[root] = agreed
        end
    end

    table.sort(plan.unapplied, function(first, second)
        return first.character < second.character
    end)
    return plan
end

-- Commits a plan to the partition. Returns counts for reporting.
function ReconcileEngine.Apply(partition, plan)
    local recorded = 0
    local key, member
    for key, member in pairs(plan.members) do
        if partition:RecordCharacter(key, member) ~= nil then
            partition:SetNoteFingerprint(key, plan.fingerprints[key])
            recorded = recorded + 1
        end
    end

    local linked = 0
    local alt, main
    for alt, main in pairs(plan.links) do
        if partition:JoinPlayerOf(alt, main, addon.FellowshipStore.SOURCE_NOTE) then
            linked = linked + 1
        end
    end

    local aliased = 0
    local alias
    for main, alias in pairs(plan.aliases) do
        local character = partition:GetCharacter(main)
        if character ~= nil
            and partition:SetAlias(character.player, alias, addon.FellowshipStore.SOURCE_NOTE)
        then
            aliased = aliased + 1
        end
    end

    partition:SetUnapplied(plan.unapplied)
    return {
        aliased = aliased,
        linked = linked,
        recorded = recorded,
        unapplied = #plan.unapplied,
    }
end
