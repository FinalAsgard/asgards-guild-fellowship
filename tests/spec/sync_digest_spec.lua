local test = require("tests.test_helper")

-- Bucketed checksums: telling whether two clients agree, and where they
-- don't, without sending the facts themselves.
local function load()
    return test.newAddon("Core/SyncFacts.lua", "Core/SyncDigest.lua").SyncDigest
end

local NOW = 1790000000

local function mainFact(index, at, by)
    return {
        kind = "main",
        character = "alt" .. index .. "-area52",
        main = "main" .. index .. "-area52",
        at = at or NOW,
        by = by or "toolbox-area52",
    }
end

local function manyFacts(count)
    local facts = {}
    local index
    for index = 1, count do
        table.insert(facts, mainFact(index))
    end
    table.insert(facts, { kind = "alias", character = "main1-area52", alias = "The Tool", at = NOW, by = "toolbox-area52" })
    return facts
end

local function reversed(list)
    local result = {}
    local index
    for index = #list, 1, -1 do
        table.insert(result, list[index])
    end
    return result
end

test.test("the same facts in any order give the same digest", function()
    local digests = load()
    local facts = manyFacts(40)

    local digest = digests.Of(facts)

    test.assertEqual(digests.BUCKETS, #digest)
    test.assertTrue(digests.IsValid(digest))
    test.assertEqual(0, #digests.Differing(digest, digests.Of(reversed(facts))))
end)

test.test("an empty set of facts has every bucket at zero", function()
    local digests = load()

    local digest = digests.Of({})

    local index
    for index = 1, digests.BUCKETS do
        test.assertEqual(0, digest[index])
    end
end)

test.test("changing one fact changes only its bucket", function()
    local digests = load()
    local facts = manyFacts(40)
    local before = digests.Of(facts)

    local changed = manyFacts(40)
    changed[7] = mainFact(7, NOW + 1)
    local differing = digests.Differing(before, digests.Of(changed))

    test.assertEqual(1, #differing)
    test.assertEqual(digests.BucketOf(facts[7]), differing[1])
    -- Who set it counts too.
    changed = manyFacts(40)
    changed[7] = mainFact(7, NOW, "gm-area52")
    test.assertEqual(1, #digests.Differing(before, digests.Of(changed)))
end)

test.test("a missing fact shows as its bucket differing", function()
    local digests = load()
    local facts = manyFacts(10)
    local fewer = manyFacts(10)
    table.remove(fewer, 3)

    local differing = digests.Differing(digests.Of(facts), digests.Of(fewer))

    test.assertEqual(1, #differing)
    test.assertEqual(digests.BucketOf(facts[3]), differing[1])
end)

test.test("a fact's bucket depends only on what it is about", function()
    local digests = load()
    local fact = mainFact(5)

    local bucket = digests.BucketOf(fact)

    test.assertTrue(bucket >= 1 and bucket <= digests.BUCKETS)
    test.assertEqual(bucket, digests.BucketOf(mainFact(5, NOW + 100, "gm-area52")))
end)

test.test("the facts in some buckets are exactly those that land there", function()
    local digests = load()
    local facts = manyFacts(40)
    local bucket = digests.BucketOf(facts[1])

    local found = digests.FactsIn(facts, { bucket })

    test.assertTrue(#found >= 1 and #found < #facts)
    local index
    for index = 1, #found do
        test.assertEqual(bucket, digests.BucketOf(found[index]))
    end
end)

test.test("digests and bucket lists from other clients are checked before use", function()
    local digests = load()
    local valid = digests.Of({})

    test.assertFalse(digests.IsValid(nil))
    test.assertFalse(digests.IsValid("digest"))
    test.assertFalse(digests.IsValid({ 1, 2, 3 }))
    local bad = digests.Of({})
    bad[4] = "x"
    test.assertFalse(digests.IsValid(bad))
    bad[4] = -1
    test.assertFalse(digests.IsValid(bad))
    bad[4] = 1.5
    test.assertFalse(digests.IsValid(bad))
    test.assertTrue(digests.IsValid(valid))

    test.assertTrue(digests.IsBucketList({ 1, digests.BUCKETS }))
    test.assertFalse(digests.IsBucketList({ 0 }))
    test.assertFalse(digests.IsBucketList({ digests.BUCKETS + 1 }))
    test.assertFalse(digests.IsBucketList({ "1" }))
    test.assertFalse(digests.IsBucketList("1"))
end)
