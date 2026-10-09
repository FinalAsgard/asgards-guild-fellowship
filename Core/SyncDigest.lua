local _, addon = ...

-- Bucketed checksums of a set of sync facts, so two clients can tell
-- whether they agree, and if not, which part of their data differs, without
-- sending the facts themselves.
--
-- Every fact lands in one of BUCKETS buckets, chosen by what it is about
-- (its kind and character), so the same fact lands in the same bucket on
-- every client. A bucket's checksum is the sum of its facts' hashes, which
-- doesn't depend on the order facts are found in. A digest is the list of
-- bucket checksums, 0 for an empty bucket.
--
-- Pure: works on fact tables and never touches the game.
local SyncDigest = {
    BUCKETS = 32,
}
addon.SyncDigest = SyncDigest

local MODULUS = 4294967296
local SEPARATOR = "\31"

-- The same string hash as note fingerprints. Every step stays below 2^53,
-- so it's exact in Lua 5.1's doubles.
local function hash(text)
    local value = 5381
    local index
    for index = 1, #text do
        value = (value * 33 + string.byte(text, index)) % MODULUS
    end
    return value
end

-- Which bucket `fact` belongs in (1 to BUCKETS).
function SyncDigest.BucketOf(fact)
    return hash(tostring(fact.kind) .. SEPARATOR .. tostring(fact.character)) % SyncDigest.BUCKETS + 1
end

local function factHash(fact)
    local value = fact.main
    if fact.kind == addon.SyncFacts.KIND_ALIAS then
        value = fact.alias
    end
    return hash(table.concat({
        tostring(fact.kind), tostring(fact.character), tostring(value), tostring(fact.at), tostring(fact.by),
    }, SEPARATOR))
end

-- The digest of a list of facts. `checkpoint`, when given, is called after
-- each fact so a scheduler can spread the work across frames.
function SyncDigest.Of(facts, checkpoint)
    local digest = {}
    local index
    for index = 1, SyncDigest.BUCKETS do
        digest[index] = 0
    end
    for index = 1, #facts do
        local bucket = SyncDigest.BucketOf(facts[index])
        digest[bucket] = (digest[bucket] + factHash(facts[index])) % MODULUS
        if checkpoint ~= nil then
            checkpoint()
        end
    end
    return digest
end

-- True when `digest` has the shape of a digest (it came from another client).
function SyncDigest.IsValid(digest)
    if type(digest) ~= "table" or #digest ~= SyncDigest.BUCKETS then
        return false
    end
    local index
    for index = 1, SyncDigest.BUCKETS do
        local value = digest[index]
        if type(value) ~= "number" or value < 0 or value >= MODULUS or value ~= math.floor(value) then
            return false
        end
    end
    return true
end

-- The buckets where two valid digests differ, in order. Empty when they agree.
function SyncDigest.Differing(mine, theirs)
    local buckets = {}
    local index
    for index = 1, SyncDigest.BUCKETS do
        if mine[index] ~= theirs[index] then
            table.insert(buckets, index)
        end
    end
    return buckets
end

-- True when `buckets` is a list of bucket numbers (it came from another
-- client).
function SyncDigest.IsBucketList(buckets)
    if type(buckets) ~= "table" or #buckets > SyncDigest.BUCKETS then
        return false
    end
    local index
    for index = 1, #buckets do
        local bucket = buckets[index]
        if type(bucket) ~= "number" or bucket < 1 or bucket > SyncDigest.BUCKETS or bucket ~= math.floor(bucket) then
            return false
        end
    end
    return true
end

-- The facts from `facts` that lie in any of `buckets`. `checkpoint`, as for
-- Of.
function SyncDigest.FactsIn(facts, buckets, checkpoint)
    local wanted = {}
    local index
    for index = 1, #buckets do
        wanted[buckets[index]] = true
    end
    local found = {}
    for index = 1, #facts do
        if wanted[SyncDigest.BucketOf(facts[index])] then
            table.insert(found, facts[index])
        end
        if checkpoint ~= nil then
            checkpoint()
        end
    end
    return found
end
