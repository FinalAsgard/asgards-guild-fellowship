local _, addon = ...

-- Compares a roster snapshot (with note text) against a guild partition and
-- plans the changes. Plan() never mutates anything; Apply() commits a plan.
--
-- Seeding: a note marker on a character with no relationship in the
-- database is applied directly, which covers the whole first scan.
--
-- Guild notes win: a note that disagrees with a link or alias nobody
-- submitted (one from notes or the roster) is applied, with no conflict.
-- Only a disagreement with something submitted through the add-on (set by
-- hand, or through guild sync) becomes a conflict, for an officer to
-- accept or reject; a suggestion rejected that way is not queued again
-- until the note changes. Markers that can't be applied at all
-- (unresolved, ambiguous, cyclic, chains that are too long, and competing
-- aliases) change nothing and queue nothing; an unresolved or ambiguous
-- one is read again when the guild's aliases change.
--
-- Departures: a full scan of a complete roster marks stored characters that
-- are missing as departed, and clears the flag on any that are back (they
-- keep their stored player). Afterwards every player that still has an
-- in-guild character gets an in-guild acting main: the highest level, then
-- the most recently online. The former main goes into the player's history.
--
-- Alias targets: a main marker naming a player's one-word alias (stored, or
-- set by a note in the same plan) joins that player, whoever its main is. A
-- note naming its own player's alias is consistent and changes nothing.
--
-- Out-of-guild mains: a marker naming a stored character who isn't in the
-- guild links to that character's player. A marker naming nobody known
-- changes nothing until an alias names someone.
local ReconcileEngine = {
    MAX_CHAIN_DEPTH = 10,
    -- The note conflicts a scan queues: a note disagreeing with a submitted
    -- main link, alias, or (on an alt) a note naming the character itself
    -- as main.
    CONFLICT_KINDS = { main = true, alias = true, ["self reference"] = true },
}
addon.ReconcileEngine = ReconcileEngine

-- Matches marker text against characters: a full name (with or without
-- realm) of a roster member or a stored character no longer in the guild,
-- or on Forever a single word as a unique first name of a roster member.
function ReconcileEngine.NewResolver(members, normalizer, twoPartNames, partition)
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
-- those are seeded from notes; a manual or synced detach or alias change is a choice
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
        or character.source == addon.FellowshipStore.SOURCE_SYNC
        or player.aliasSource == manual
        or player.aliasSource == addon.FellowshipStore.SOURCE_SYNC
end

-- True when `player`'s alias was set or cleared by hand or through sync.
local function aliasSubmitted(player)
    return player ~= nil and (player.aliasSource == addon.FellowshipStore.SOURCE_MANUAL
        or player.aliasSource == addon.FellowshipStore.SOURCE_SYNC)
end

-- True when `player` has no alias and nobody ever set or cleared one by
-- hand or through sync, so a note may name it.
local function aliasUntouched(player)
    return player ~= nil and player.alias == nil and not aliasSubmitted(player)
end

-- True when `key`'s place in its player was set by hand or through sync,
-- rather than by notes or the roster.
local function linkSubmitted(partition, key)
    local character = partition:GetCharacter(key)
    return character ~= nil and (character.source == addon.FellowshipStore.SOURCE_MANUAL
        or character.source == addon.FellowshipStore.SOURCE_SYNC)
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
        if nextRef ~= nil and nextRef.status == "resolved" and nextRef.player ~= nil then
            -- A note naming a stored player's alias ends at that player's main.
            local player = partition:GetPlayer(nextRef.player)
            return player and player.main or current
        end
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

-- The main a resolved ref on `key`'s note leads to: a named player's
-- current main, or the end of the chain of notes. Returns nil and a reason
-- when the chain can't be followed.
local function rootOf(key, ref, parseOf, partition, sizes)
    if ref.player ~= nil then
        local player = partition:GetPlayer(ref.player)
        if player == nil then
            return nil, "unresolved"
        end
        return player.main
    end
    return followChain(key, ref.key, parseOf, partition, sizes)
end

-- Queues a conflict, unless an officer already rejected this note.
local function addConflict(plan, partition, key, kind, suggestion)
    local character = partition:GetCharacter(key)
    if character ~= nil and character.rejected ~= nil
        and character.rejected[kind] == plan.fingerprints[key]
    then
        return
    end
    local entry = {
        character = key,
        fingerprint = plan.fingerprints[key],
        kind = kind,
        suggestion = suggestion,
    }
    table.insert(plan.conflicts, entry)
end

-- Which roster characters a plan processes:
--   "initial"      every character (the first scan of a guild)
--   "full" and "incremental"
--                  characters whose note fingerprint changed, plus new ones,
--                  and those whose note was never processed (a scan was cut
--                  short); a full scan with `force` takes every character (a
--                  manual rescan)
-- Characters whose note is unchanged are skipped entirely, so repeat scans
-- do no per-character reconciliation work.
local function selects(mode, force, partition, key, fingerprint)
    local character = partition:GetCharacter(key)
    if character == nil or mode == "initial" or (force and mode ~= "incremental") then
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
--   aliasNotes   main key -> keys of the characters whose notes set that alias
--   declared     character keys whose own note names them as main: they're
--                declared mains
--   moves        organized key -> the main key whose player its note names,
--                where nobody submitted its link (the note wins)
--   splits       alts whose own note names them as main, where nobody
--                submitted their link: each leaves for a player of its own
--   retry        keys whose main marker names nobody, or several players:
--                read again when the guild's aliases change, or when someone
--                new is in the roster
--   notesChanged how many known characters' notes differ from the ones
--                last processed
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
    local resolver = ReconcileEngine.NewResolver(members, inputs.normalizer, rules.twoPartNames == true, partition)
    local sizes = playerSizes(partition)
    local plan = {
        aliases = {},
        fingerprints = {},
        aliasNotes = {},
        declared = {},
        links = {},
        moves = {},
        splits = {},
        retry = {},
        notesChanged = 0,
        members = members,
        mode = mode,
        newKeys = {},
        processed = {},
        conflicts = {},
        departures = {},
        rejoins = {},
        now = inputs.now or 0,
    }

    -- A main marker's word names an alias before a character. Aliases come
    -- from the store and from the notes this plan reads, so a first scan
    -- links `>Tool` to the player whose note says `@Tool`.
    local storedTargets = {}
    local function storedAliasResolver(word)
        local folded = string.lower(word)
        if storedTargets[folded] == nil then
            local targets = {}
            local ids = partition:PlayersWithAlias(word)
            local index
            for index = 1, #ids do
                table.insert(targets, { player = ids[index] })
            end
            storedTargets[folded] = targets
        end
        return storedTargets[folded]
    end

    -- Notes read against stored aliases only, to work out which player each
    -- note's own alias will name.
    local storedParses = {}
    local function storedParseOf(key)
        if storedParses[key] == nil and members[key] ~= nil then
            storedParses[key] = addon.NoteParser.Parse(members[key].note, resolver, rules, storedAliasResolver, key)
        end
        return storedParses[key]
    end

    -- Folded alias -> keys of processed characters whose notes carry it.
    local noteAliases = {}

    -- The target a note's `@Alias` on `key` names: the stored player, when
    -- `key` (or the main its note leads to) is organized and nobody named
    -- that player by hand or through sync; otherwise the root character
    -- the plan will make the main. Nil when the note can't name a player.
    local function noteAliasTarget(key)
        local root = key
        if not hasRelationship(partition, sizes, key) then
            local ref = storedParseOf(key).mainRef
            if ref ~= nil and ref.status == "resolved" and ref.key ~= key then
                root = rootOf(key, ref, storedParseOf, partition, sizes) or key
            end
        end
        local rootCharacter = partition:GetCharacter(root)
        if rootCharacter ~= nil and hasRelationship(partition, sizes, root) then
            local player = partition:GetPlayer(rootCharacter.player)
            if aliasUntouched(player) then
                return { player = rootCharacter.player }
            end
            -- Already named: the store's alias is what counts.
            return nil
        end
        return { key = root }
    end

    local aliasTargets = {}
    local function aliasResolver(word)
        local folded = string.lower(word)
        if aliasTargets[folded] ~= nil then
            return aliasTargets[folded]
        end
        local targets = {}
        local players, roots = {}, {}
        local function add(target)
            if target == nil then
                return
            end
            if target.player ~= nil and not players[target.player] then
                players[target.player] = true
                table.insert(targets, target)
            elseif target.key ~= nil and not roots[target.key] then
                roots[target.key] = true
                table.insert(targets, target)
            end
        end
        local stored = storedAliasResolver(word)
        local index
        for index = 1, #stored do
            add(stored[index])
        end
        -- A note whose own main marker names the alias it carries only
        -- follows the others; it names a player only when nothing else does.
        local followers = {}
        local sources = noteAliases[folded] or {}
        for index = 1, #sources do
            local ref = storedParseOf(sources[index]).mainRef
            if ref ~= nil and ref.status ~= "resolved" and string.lower(ref.text) == folded then
                table.insert(followers, sources[index])
            else
                add(noteAliasTarget(sources[index]))
            end
        end
        if #targets == 0 then
            for index = 1, #followers do
                add(noteAliasTarget(followers[index]))
            end
        end
        aliasTargets[folded] = targets
        return targets
    end

    -- Notes are parsed only when needed: for processed characters, and for
    -- the targets of a chain being followed.
    local parses = {}
    local function parseOf(key)
        if parses[key] == nil and members[key] ~= nil then
            parses[key] = addon.NoteParser.Parse(members[key].note, resolver, rules, aliasResolver, key)
        end
        return parses[key]
    end

    local keys = {}
    local key, member
    -- A new member may be the one a waiting marker names, so markers that
    -- matched nobody are read again whenever someone new is in the roster.
    local joined = false
    for key in pairs(members) do
        if partition:GetCharacter(key) == nil then
            joined = true
            break
        end
    end
    for key, member in pairs(members) do
        plan.fingerprints[key] = addon.NoteParser.Fingerprint(member.note or "")
        if partition:GetCharacter(key) == nil then
            table.insert(plan.newKeys, key)
        end
        local stored = partition:GetCharacter(key)
        if selects(mode, inputs.force, partition, key, plan.fingerprints[key])
            or (joined and stored ~= nil and stored.awaitsAlias == true)
        then
            table.insert(keys, key)
            plan.processed[key] = true
            local character = partition:GetCharacter(key)
            if character ~= nil and character.note ~= nil and character.note ~= plan.fingerprints[key] then
                plan.notesChanged = plan.notesChanged + 1
            end
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
        local alias = addon.NoteParser.Alias(members[key].note)
        if alias ~= nil then
            local folded = string.lower(alias)
            noteAliases[folded] = noteAliases[folded] or {}
            table.insert(noteAliases[folded], key)
        end
    end

    for index = 1, #keys do
        key = keys[index]
        local ref = parseOf(key).mainRef
        if ref ~= nil then
            if ref.status == "unresolved" or ref.status == "ambiguous" then
                -- Nothing to apply until an alias settles who it names.
                plan.retry[key] = true
            elseif ref.status ~= "resolved" then
                -- Nothing the note says can be applied.
            elseif ref.byAlias and (ref.key == key or (ref.player ~= nil and partition:GetCharacter(key) ~= nil
                and partition:GetCharacter(key).player == ref.player))
            then
                -- A note naming its own player's alias is consistent: it
                -- changes nothing and declares nothing.
            elseif ref.key == key then
                -- A note naming the character itself as main declares it a
                -- main: seeded on a character nobody organized yet, filled in
                -- on a player's main nobody declared (or un-declared) by
                -- hand or through sync. On an alt, the note wins unless its
                -- link was submitted: it leaves for a player of its own.
                local character = partition:GetCharacter(key)
                local player = character and partition:GetPlayer(character.player)
                if seedable[key] or (player ~= nil and player.main == key) then
                    if not partition:IsDeclared(key) and (character == nil or partition:DeclaredUntouched(key)) then
                        plan.declared[key] = true
                    end
                elseif linkSubmitted(partition, key) then
                    addConflict(plan, partition, key, "self reference")
                else
                    plan.splits[key] = true
                    if not partition:IsDeclared(key) and partition:DeclaredUntouched(key) then
                        plan.declared[key] = true
                    end
                end
            else
                local root = rootOf(key, ref, parseOf, partition, sizes)
                if root == nil then
                    -- A cycle or a chain too long: nothing to apply.
                    if ref.player ~= nil then
                        plan.retry[key] = true
                    end
                elseif seedable[key] then
                    if root ~= key then
                        plan.links[key] = root
                    end
                else
                    -- Already organized: a note naming a different player
                    -- wins, unless the link was submitted; then it's for an
                    -- officer to decide.
                    local rootCharacter = partition:GetCharacter(root)
                    local character = partition:GetCharacter(key)
                    -- A root the store hasn't seen is a new roster member,
                    -- recorded before moves are applied.
                    if rootCharacter ~= nil and rootCharacter.player == character.player then
                        -- The note agrees.
                    elseif linkSubmitted(partition, key) then
                        addConflict(plan, partition, key, "main", { main = root })
                    else
                        plan.moves[key] = root
                    end
                end
            end
        end
        checkpoint()
    end

    -- A move to a main that moves too follows it to where it goes. Moves
    -- that lead back to where they started (notes naming each other's
    -- players) change nothing.
    local moves = {}
    local target
    for key, target in pairs(plan.moves) do
        local seen = { [key] = true }
        while plan.moves[target] ~= nil and not seen[target] do
            seen[target] = true
            target = plan.moves[target]
        end
        if not seen[target] then
            moves[key] = target
        end
    end
    plan.moves = moves

    -- An alias on any character's note names that character's player: the
    -- one it joins or moves to, or the one it splits off as. It is applied
    -- unless someone named (or un-named) the player by hand or through
    -- sync; then a different alias is a conflict. Notes that disagree with
    -- each other change nothing.
    local proposals = {}
    for index = 1, #keys do
        key = keys[index]
        local alias = parseOf(key).alias
        if alias ~= nil then
            local root = plan.links[key] or plan.moves[key] or key
            proposals[root] = proposals[root] or {}
            table.insert(proposals[root], { alias = alias, character = key })
        end
    end
    -- Organized players' notes, by player: { main, alias, entries }.
    local fills = {}
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
            -- Competing aliases: nothing to apply.
        elseif rootCharacter == nil or not hasRelationship(partition, sizes, root) or plan.splits[root] then
            plan.aliases[root] = agreed
            plan.aliasNotes[root] = {}
            for index = 1, #entries do
                table.insert(plan.aliasNotes[root], entries[index].character)
            end
        elseif not aliasSubmitted(player) then
            -- Notes on several of its characters can name the player, or
            -- rename it when notes named it: the notes win.
            local fill = fills[rootCharacter.player]
            if fill == nil then
                fill = { main = player.main, alias = player.alias, entries = {} }
                fills[rootCharacter.player] = fill
            end
            for index = 1, #entries do
                table.insert(fill.entries, entries[index])
            end
        elseif player.alias == nil or string.lower(player.alias) ~= folded then
            for index = 1, #entries do
                addConflict(plan, partition, entries[index].character, "alias", { alias = agreed })
            end
        end
    end
    local fill
    for _, fill in pairs(fills) do
        table.sort(fill.entries, function(first, second)
            return first.character < second.character
        end)
        local agreed = fill.entries[1].alias
        local index
        for index = 2, #fill.entries do
            if string.lower(fill.entries[index].alias) ~= string.lower(agreed) then
                agreed = nil
                break
            end
        end
        if agreed ~= nil and (fill.alias == nil or string.lower(fill.alias) ~= string.lower(agreed)) then
            plan.aliases[fill.main] = agreed
            plan.aliasNotes[fill.main] = {}
            for index = 1, #fill.entries do
                table.insert(plan.aliasNotes[fill.main], fill.entries[index].character)
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

-- Records in `playerId`'s history that `key` left it because of its note.
-- Nothing is recorded when the old player is gone (it had no other
-- characters).
local function recordLeaving(partition, playerId, key, wasMain, now, reason)
    local character = partition:GetCharacter(key)
    if character == nil or partition:GetPlayer(playerId) == nil then
        return
    end
    partition:AddHistory(playerId, {
        name = character.name or key,
        character = key,
        role = wasMain and "main" or "alt",
        ["until"] = now,
        reason = reason,
    })
end

-- Commits a plan to the partition. `checkpoint` is called between
-- characters, as in Plan. Returns counts for reporting:
--   recorded, newCharacters (and newKeys, their keys), linked (by notes, moves
--   included), aliased, conflicts, departed, rejoined, promoted, notesChanged
function ReconcileEngine.Apply(partition, plan, checkpoint)
    checkpoint = checkpoint or function() end

    -- Every scan refreshes the lasting facts (rank, level) of the
    -- characters it read; an incremental one only adds the new characters
    -- it found.
    local recorded = 0
    local key, member
    for key, member in pairs(plan.members) do
        if plan.mode ~= "incremental" or plan.processed[key] or partition:GetCharacter(key) ~= nil then
            if partition:RecordCharacter(key, member) ~= nil then
                recorded = recorded + 1
            end
            checkpoint()
        end
    end

    -- Nothing below yields, so no manual change can land between these
    -- checks and the writes. Planning yielded, though, so each seed is
    -- checked again: a character organized since then is left alone.
    --
    -- A note whose seed is skipped that way is left unprocessed: the next
    -- scan reads it again against the character as it is organized now.
    local unprocessed = {}
    local sizes = playerSizes(partition)
    local linked = 0
    local alt, main
    for alt, main in pairs(plan.links) do
        if hasRelationship(partition, sizes, alt) then
            unprocessed[alt] = true
        elseif partition:JoinPlayerOf(alt, main, addon.FellowshipStore.SOURCE_NOTE) then
            linked = linked + 1
        end
    end

    -- Notes that win over links nobody submitted. A link submitted since
    -- planning is left alone, and its note read again by the next scan.
    for alt, main in pairs(plan.moves) do
        local character = partition:GetCharacter(alt)
        if character == nil or partition:GetCharacter(main) == nil or linkSubmitted(partition, alt) then
            unprocessed[alt] = true
        else
            local formerPlayer = character.player
            local wasMain = partition:GetPlayer(formerPlayer).main == alt
            if partition:JoinPlayerOf(alt, main, addon.FellowshipStore.SOURCE_NOTE) then
                linked = linked + 1
                recordLeaving(partition, formerPlayer, alt, wasMain, plan.now, "moved by a guild note")
            end
        end
    end
    local split
    for split in pairs(plan.splits) do
        local character = partition:GetCharacter(split)
        if character == nil or linkSubmitted(partition, split) then
            unprocessed[split] = true
        else
            local formerPlayer = character.player
            if partition:MoveToNewPlayer(split, addon.FellowshipStore.SOURCE_NOTE) ~= nil then
                linked = linked + 1
                recordLeaving(partition, formerPlayer, split, false, plan.now, "made a main by a guild note")
            end
        end
    end

    local aliased = 0
    local alias
    for main, alias in pairs(plan.aliases) do
        local character = partition:GetCharacter(main)
        local player = character and partition:GetPlayer(character.player)
        -- The plan's own links may have given this player alts; what must
        -- still hold is that nobody named it, or cleared its name, by hand or
        -- through sync. A name notes gave it, the notes may change.
        if player ~= nil and player.main == main and not aliasSubmitted(player) then
            if partition:SetAlias(character.player, alias, addon.FellowshipStore.SOURCE_NOTE) then
                aliased = aliased + 1
            end
        else
            local notes = plan.aliasNotes[main] or {}
            local index
            for index = 1, #notes do
                unprocessed[notes[index]] = true
            end
        end
    end

    -- Declared mains from notes: still each player's main, and still not
    -- declared or un-declared by hand or through sync.
    local declared = 0
    local declaredKey
    for declaredKey in pairs(plan.declared) do
        local character = partition:GetCharacter(declaredKey)
        local player = character and partition:GetPlayer(character.player)
        if player ~= nil and player.main == declaredKey and partition:DeclaredUntouched(declaredKey)
            and partition:SetDeclared(declaredKey, true, addon.FellowshipStore.SOURCE_NOTE)
        then
            declared = declared + 1
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
    -- characters get exactly the conflicts this plan found. Members'
    -- suggestions wait for an officer to decide them, whatever is rescanned.
    -- New acting mains are recorded in their player's history, not queued.
    local conflicts = {}
    local previous = partition:GetConflicts() or {}
    for index = 1, #previous do
        local entry = previous[index]
        if type(entry) == "table" and (entry.from ~= nil
            or (not plan.processed[entry.character] and ReconcileEngine.CONFLICT_KINDS[entry.kind]))
        then
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

    -- Notes count as processed only now, once their links, aliases, and
    -- conflicts are saved, so a scan cut short (a reload or logout) is
    -- redone by the next scan instead of skipped as unchanged. Notes whose
    -- seed was skipped above stay unprocessed too.
    for key in pairs(plan.processed) do
        if not unprocessed[key] and partition:GetCharacter(key) ~= nil then
            partition:SetNoteFingerprint(key, plan.fingerprints[key])
            partition:SetAwaitsAlias(key, plan.retry[key] == true)
            -- Aliases this apply changed came after the marker was read, so
            -- it is read again by the next scan, as AliasesChanged does.
            if aliased > 0 and plan.retry[key] then
                partition:ForgetNoteFingerprint(key)
            end
        end
    end

    return {
        aliased = aliased,
        linked = linked,
        newCharacters = #plan.newKeys,
        newKeys = plan.newKeys,
        recorded = recorded,
        conflicts = #plan.conflicts,
        notesChanged = plan.notesChanged,
        departed = departed,
        rejoined = rejoined,
        promoted = #promotions,
        declared = declared,
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
-- player's history. Returns the promotions, { character, former }.
-- `checkpoint`, when given, is called after each player.
function ReconcileEngine.EnsureActingMains(partition, members, now, checkpoint)
    members = members or {}
    checkpoint = checkpoint or function() end
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
                table.insert(promotions, { character = best, former = formerKey })
            end
        end
        checkpoint()
    end
    return promotions
end
