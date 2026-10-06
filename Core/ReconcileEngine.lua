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
-- Departures: a full scan of a complete roster marks stored characters that
-- are missing as departed, and clears the flag on any that are back (they
-- keep their stored player). Afterwards every player that still has an
-- in-guild character gets an in-guild acting main: the highest level, then
-- the most recently online. The former main goes into the player's history,
-- and a confirmation conflict is queued.
--
-- Out-of-guild mains: a marker naming a stored character who isn't in the
-- guild links to that character's player. A marker naming nobody known is an
-- "unresolved" conflict whose suggestion, if accepted, records the name as
-- the player's out-of-guild main.
local ReconcileEngine = {
    MAX_CHAIN_DEPTH = 10,
}
addon.ReconcileEngine = ReconcileEngine

-- Matches marker text against characters: a full name (with or without
-- realm) of a roster member or a stored character no longer in the guild,
-- or on Forever a single word as a unique first name of a roster member.
local function newResolver(members, normalizer, twoPartNames, partition)
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
        if key ~= nil and (members[key] ~= nil or partition:GetCharacter(key) ~= nil) then
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
-- and unnamed member of its own player that nobody organized by hand. Only
-- those are seeded from notes; a manual detach or alias change is a choice
-- that only the conflict queue may change.
local function hasRelationship(partition, sizes, key)
    local character = partition:GetCharacter(key)
    if character == nil then
        return false
    end
    local player = partition:GetPlayer(character.player)
    local manual = addon.FellowshipStore.SOURCE_MANUAL
    return player == nil
        or player.main ~= key
        or player.alias ~= nil
        or (sizes[character.player] or 0) > 1
        or character.source == manual
        or player.aliasSource == manual
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
--   departures   stored keys missing from the roster (full scans only)
--   rejoins      departed keys back in the roster
--   now          the scan's timestamp (inputs.now)
function ReconcileEngine.Plan(inputs)
    local partition = inputs.partition
    local members = inputs.members or {}
    local rules = inputs.rules or {}
    local checkpoint = inputs.checkpoint or function() end
    local mode = inputs.mode or "initial"
    local resolver = newResolver(members, inputs.normalizer, rules.twoPartNames == true, partition)
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
        departures = {},
        rejoins = {},
        now = inputs.now or 0,
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

    -- Departures need the whole roster, so incremental checks never declare
    -- them. Callers only pass complete roster reads.
    if mode ~= "incremental" and next(members) ~= nil then
        partition:EachCharacter(function(storedKey, character)
            if members[storedKey] == nil and character.departed == nil then
                table.insert(plan.departures, storedKey)
            end
        end)
        table.sort(plan.departures)
    end
    for key in pairs(members) do
        local character = partition:GetCharacter(key)
        if character ~= nil and character.departed ~= nil then
            table.insert(plan.rejoins, key)
        end
    end
    table.sort(plan.rejoins)

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
            if ref.status == "unresolved" then
                -- Accepting records the name as an out-of-guild main.
                addConflict(plan, partition, key, ref.status, { outOfGuild = ref.text })
            elseif ref.status ~= "resolved" then
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
--   recorded, newCharacters, linked, aliased, conflicts, departed,
--   rejoined, promoted
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
            end
            checkpoint()
        end
    end

    -- Nothing below yields, so no manual change can land between these
    -- checks and the writes. Planning yielded, though, so each seed is
    -- checked again: a character organized since then is left alone.
    local sizes = playerSizes(partition)
    local linked = 0
    local alt, main
    for alt, main in pairs(plan.links) do
        if not hasRelationship(partition, sizes, alt)
            and partition:JoinPlayerOf(alt, main, addon.FellowshipStore.SOURCE_NOTE)
        then
            linked = linked + 1
        end
    end

    local aliased = 0
    local alias
    for main, alias in pairs(plan.aliases) do
        local character = partition:GetCharacter(main)
        local player = character and partition:GetPlayer(character.player)
        -- The plan's own links may have given this player alts; what must
        -- still hold is that nobody named it or organized it by hand.
        if player ~= nil and player.main == main and player.alias == nil
            and player.aliasSource ~= addon.FellowshipStore.SOURCE_MANUAL
            and character.source ~= addon.FellowshipStore.SOURCE_MANUAL
            and partition:SetAlias(character.player, alias, addon.FellowshipStore.SOURCE_NOTE)
        then
            aliased = aliased + 1
        end
    end

    local departed, rejoined = 0, 0
    local index
    for index = 1, #plan.departures do
        if partition:MarkDeparted(plan.departures[index], plan.now) then
            departed = departed + 1
        end
    end
    for index = 1, #plan.rejoins do
        if partition:MarkRejoined(plan.rejoins[index]) then
            rejoined = rejoined + 1
        end
    end
    local promotions = ReconcileEngine.EnsureActingMains(partition, plan.members, plan.now)

    -- Characters this plan skipped keep their pending conflicts; processed
    -- characters get exactly the conflicts this plan found.
    local conflicts = {}
    local previous = partition:GetConflicts() or {}
    for index = 1, #previous do
        local entry = previous[index]
        -- Promotions wait for the player to confirm them, whatever is
        -- rescanned.
        if type(entry) == "table" and (not plan.processed[entry.character] or entry.kind == "promotion") then
            table.insert(conflicts, entry)
        end
    end
    for index = 1, #plan.conflicts do
        table.insert(conflicts, plan.conflicts[index])
    end
    for index = 1, #promotions do
        table.insert(conflicts, promotions[index])
    end
    table.sort(conflicts, function(first, second)
        if first.character ~= second.character then
            return tostring(first.character) < tostring(second.character)
        end
        return tostring(first.kind) < tostring(second.kind)
    end)
    partition:SetConflicts(conflicts)

    -- Notes count as processed only now, once their links, aliases, and
    -- conflicts are saved, so a scan cut short (a reload or logout) is
    -- redone by the next scan instead of skipped as unchanged.
    for key in pairs(plan.processed) do
        if partition:GetCharacter(key) ~= nil then
            partition:SetNoteFingerprint(key, plan.fingerprints[key])
        end
    end

    return {
        aliased = aliased,
        linked = linked,
        newCharacters = #plan.newKeys,
        recorded = recorded,
        conflicts = #plan.conflicts + #promotions,
        departed = departed,
        rejoined = rejoined,
        promoted = #promotions,
    }
end

-- The in-guild character that should act as main: highest level, then
-- online now, then most recently online, then by key.
local function lastOnlineHours(live)
    local last = live and live.lastOnline
    if live and live.online then
        return -1
    end
    if type(last) ~= "table" then
        return math.huge
    end
    return (last.years or 0) * 8760 + (last.months or 0) * 730 + (last.days or 0) * 24 + (last.hours or 0)
end

local function bestActingMain(partition, keys, members)
    local best
    local index
    for index = 1, #keys do
        local key = keys[index]
        if partition:IsInGuild(key) then
            if best == nil then
                best = key
            else
                local candidate, current = partition:GetCharacter(key), partition:GetCharacter(best)
                local candidateLevel, currentLevel = candidate.level or 0, current.level or 0
                local candidateSeen, currentSeen = lastOnlineHours(members[key]), lastOnlineHours(members[best])
                if candidateLevel > currentLevel
                    or (candidateLevel == currentLevel and candidateSeen < currentSeen)
                    or (candidateLevel == currentLevel and candidateSeen == currentSeen and key < best)
                then
                    best = key
                end
            end
        end
    end
    return best
end

-- Keeps the invariant: a player with any in-guild character has an
-- in-guild acting main. Each promotion records the former main in the
-- player's history and returns a "promotion" conflict for confirmation.
function ReconcileEngine.EnsureActingMains(partition, members, now)
    members = members or {}
    local promotions = {}
    local players = {}
    partition:EachPlayer(function(id, player)
        table.insert(players, { id = id, player = player })
    end)
    table.sort(players, function(first, second)
        return first.id < second.id
    end)
    local index
    for index = 1, #players do
        local id, player = players[index].id, players[index].player
        if not partition:IsInGuild(player.main) then
            local keys = partition:CharactersOf(id)
            local best = bestActingMain(partition, keys, members)
            if best ~= nil then
                local formerKey = player.main
                local former = partition:GetCharacter(formerKey)
                partition:AddHistory(id, {
                    character = formerKey,
                    name = (former and former.name) or formerKey,
                    role = "main",
                    ["until"] = (former and former.departed) or now,
                    reason = former and "departed" or "out of guild",
                })
                partition:SetMain(id, best)
                table.insert(promotions, {
                    character = best,
                    kind = "promotion",
                    suggestion = { main = best, former = formerKey },
                })
            end
        end
    end
    return promotions
end
