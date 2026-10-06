local _, addon = ...

-- Compares a roster snapshot (with note text) against a guild partition and
-- plans the changes. Plan() never mutates anything; Apply() commits a plan.
--
-- Seeding: a note marker on a character with no relationship in the
-- database is applied directly, which covers the whole first scan.
--
-- Conflicts: the database is the source of truth, so a note that disagrees
-- with an existing relationship or alias never changes anything. It becomes
-- a conflict for the player to accept or reject, as do markers that can't be
-- applied at all (unresolved, ambiguous, cyclic, self-referencing, chains
-- that are too long, and competing aliases). A suggestion the player
-- rejected is not queued again until the note changes.
--
-- Departures and out-of-guild mains come in a later slice.
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
local function followChain(start, target, parseOf, partition, sizes)
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

        local parse = parseOf(current)
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

-- Queues a conflict, unless the player already rejected this note.
local function addConflict(plan, partition, key, kind, suggestion)
    local character = partition:GetCharacter(key)
    if character ~= nil and character.rejected ~= nil
        and character.rejected[kind] == plan.fingerprints[key]
    then
        return
    end
    table.insert(plan.conflicts, {
        character = key,
        fingerprint = plan.fingerprints[key],
        kind = kind,
        suggestion = suggestion,
    })
end

-- Which roster characters a plan processes:
--   "initial"      every character (the first scan of a guild)
--   "full"         characters whose note fingerprint changed, plus new ones;
--                  with `force`, every character (a manual rescan)
--   "incremental"  only characters the store has never seen
-- Characters whose note is unchanged are skipped entirely, so repeat scans
-- do no per-character reconciliation work.
local function selects(mode, force, partition, key, fingerprint)
    local character = partition:GetCharacter(key)
    if character == nil then
        return true
    end
    if mode == "incremental" then
        return false
    end
    if mode == "initial" or force then
        return true
    end
    return character.note ~= fingerprint
end

-- inputs: partition, members (key -> roster facts with `note`), normalizer,
-- rules (client name rules), mode ("initial", "full", or "incremental"),
-- force (reprocess every character), and checkpoint (called between
-- characters so a scheduler can spread the work across frames).
-- Returns a plan:
--   members      key -> roster facts to record
--   fingerprints key -> note fingerprint (never the note text)
--   processed    set of keys this plan reconciled
--   newKeys      keys the store hadn't seen
--   links        alt key -> the main key whose player it joins
--   aliases      main key -> alias for that main's player
--   conflicts    { character, kind, fingerprint, suggestion? } to queue
function ReconcileEngine.Plan(inputs)
    local partition = inputs.partition
    local members = inputs.members or {}
    local rules = inputs.rules or {}
    local checkpoint = inputs.checkpoint or function() end
    local mode = inputs.mode or "initial"
    local resolver = newResolver(members, inputs.normalizer, rules.twoPartNames == true)
    local sizes = playerSizes(partition)
    local plan = {
        aliases = {},
        fingerprints = {},
        links = {},
        members = members,
        mode = mode,
        newKeys = {},
        processed = {},
        conflicts = {},
    }

    -- Notes are parsed only when needed: for processed characters, and for
    -- the targets of a chain being followed.
    local parses = {}
    local function parseOf(key)
        if parses[key] == nil and members[key] ~= nil then
            parses[key] = addon.NoteParser.Parse(members[key].note, resolver, rules)
        end
        return parses[key]
    end

    local keys = {}
    local key, member
    for key, member in pairs(members) do
        plan.fingerprints[key] = addon.NoteParser.Fingerprint(member.note or "")
        if partition:GetCharacter(key) == nil then
            table.insert(plan.newKeys, key)
        end
        if selects(mode, inputs.force, partition, key, plan.fingerprints[key]) then
            table.insert(keys, key)
            plan.processed[key] = true
        end
        checkpoint()
    end
    -- Plans are deterministic whatever order the roster comes in.
    table.sort(keys)
    table.sort(plan.newKeys)

    local seedable = {}
    local index
    for index = 1, #keys do
        key = keys[index]
        seedable[key] = not hasRelationship(partition, sizes, key)
    end

    for index = 1, #keys do
        key = keys[index]
        local ref = parseOf(key).mainRef
        if ref ~= nil then
            if ref.status ~= "resolved" then
                addConflict(plan, partition, key, ref.status)
            elseif ref.key == key then
                addConflict(plan, partition, key, "self reference")
            else
                local root, reason = followChain(key, ref.key, parseOf, partition, sizes)
                if root == nil then
                    addConflict(plan, partition, key, reason)
                elseif seedable[key] then
                    if root ~= key then
                        plan.links[key] = root
                    end
                else
                    -- Already organized: a note naming a different player
                    -- is drift, for the player to decide.
                    local rootCharacter = partition:GetCharacter(root)
                    local character = partition:GetCharacter(key)
                    if rootCharacter == nil or rootCharacter.player ~= character.player then
                        addConflict(plan, partition, key, "main", { main = root })
                    end
                end
            end
        end
        checkpoint()
    end

    -- An alias on any character's note names that character's player. On
    -- unorganized players it is applied; on organized ones a different
    -- alias is drift.
    local proposals = {}
    for index = 1, #keys do
        key = keys[index]
        local alias = parseOf(key).alias
        if alias ~= nil then
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
        local rootCharacter = partition:GetCharacter(root)
        local player = rootCharacter and partition:GetPlayer(rootCharacter.player)
        if agreed == nil then
            for index = 1, #entries do
                addConflict(plan, partition, entries[index].character, "competing aliases")
            end
        elseif rootCharacter == nil or not hasRelationship(partition, sizes, root) then
            plan.aliases[root] = agreed
        elseif player.alias == nil or string.lower(player.alias) ~= folded then
            for index = 1, #entries do
                addConflict(plan, partition, entries[index].character, "alias", { alias = agreed })
            end
        end
    end

    table.sort(plan.conflicts, function(first, second)
        if first.character ~= second.character then
            return first.character < second.character
        end
        return first.kind < second.kind
    end)
    return plan
end

-- Commits a plan to the partition. `checkpoint` is called between
-- characters, as in Plan. Returns counts for reporting:
--   recorded, newCharacters, linked, aliased, conflicts
function ReconcileEngine.Apply(partition, plan, checkpoint)
    checkpoint = checkpoint or function() end

    -- Full scans refresh every character's lasting facts; incremental scans
    -- only add the characters they found.
    local recorded = 0
    local key, member
    for key, member in pairs(plan.members) do
        if plan.mode ~= "incremental" or plan.processed[key] then
            if partition:RecordCharacter(key, member) ~= nil then
                recorded = recorded + 1
                if plan.processed[key] then
                    partition:SetNoteFingerprint(key, plan.fingerprints[key])
                end
            end
            checkpoint()
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

    -- Characters this plan skipped keep their pending conflicts; processed
    -- characters get exactly the conflicts this plan found.
    local conflicts = {}
    local previous = partition:GetConflicts() or {}
    local index
    for index = 1, #previous do
        local entry = previous[index]
        if type(entry) == "table" and not plan.processed[entry.character] then
            table.insert(conflicts, entry)
        end
    end
    for index = 1, #plan.conflicts do
        table.insert(conflicts, plan.conflicts[index])
    end
    table.sort(conflicts, function(first, second)
        if first.character ~= second.character then
            return tostring(first.character) < tostring(second.character)
        end
        return tostring(first.kind) < tostring(second.kind)
    end)
    partition:SetConflicts(conflicts)

    return {
        aliased = aliased,
        linked = linked,
        newCharacters = #plan.newKeys,
        recorded = recorded,
        conflicts = #plan.conflicts,
    }
end
