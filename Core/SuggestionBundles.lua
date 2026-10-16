local _, addon = ...

-- Members' suggestions seen as one request per player. Suggestions travel
-- and are decided one at a time (SuggestionService); this groups them by
-- the player who made them and says what each one asks for in plain words.
-- Pure: works on a FellowshipStore partition and a NameNormalizer.
local SuggestionBundles = {}
addon.SuggestionBundles = SuggestionBundles

local function nameOf(partition, normalizer, key)
    local character = partition:GetCharacter(key)
    return normalizer:Display(character and character.name or key) or key
end

-- What a suggestion fact asks for: "Wrench as an alt of Hammer", "Hammer
-- as main", "Alias: Tools", "Clear the alias", "Hammer declared as main",
-- "Hammer no longer declared", "Hammer's Discord: hammer#1", or "Clear
-- Hammer's Discord".
function SuggestionBundles.Describe(partition, normalizer, fact)
    if fact.kind == addon.SyncFacts.KIND_DISCORD then
        local name = nameOf(partition, normalizer, fact.character)
        if fact.text == "" then
            return "Clear " .. name .. "'s Discord"
        end
        return name .. "'s Discord: " .. tostring(fact.text)
    end
    if fact.kind == addon.SyncFacts.KIND_DECLARED then
        local name = nameOf(partition, normalizer, fact.character)
        return fact.declared and (name .. " declared as main") or (name .. " no longer declared")
    end
    if fact.kind == addon.SyncFacts.KIND_ALIAS then
        if fact.alias == "" then
            return "Clear the alias"
        end
        return "Alias: " .. fact.alias
    end
    local name = nameOf(partition, normalizer, fact.character)
    if fact.main == fact.character then
        return name .. " as main"
    end
    return name .. " as an alt of " .. nameOf(partition, normalizer, fact.main)
end

-- The member's pending suggestions (SuggestionService:Pending) made by any
-- character of `playerId`, from any entry point, oldest first, each:
--   { character, kind, text, canUndo }
-- `kind` is the fact kind ("main" or "alias"); `canUndo` is whether the
-- value it replaced is known, so it can be undone.
function SuggestionBundles.MemberItems(partition, normalizer, playerId, pending)
    local items = {}
    local index
    for index = 1, #(pending or {}) do
        local fact = pending[index]
        local author = partition:GetCharacter(fact.by)
        if author ~= nil and author.player == playerId then
            table.insert(items, {
                character = fact.character,
                kind = fact.kind,
                at = fact.at,
                text = SuggestionBundles.Describe(partition, normalizer, fact),
                canUndo = fact.was ~= nil,
            })
        end
    end
    table.sort(items, function(first, second)
        if first.at ~= second.at then
            return first.at < second.at
        end
        return first.character < second.character
    end)
    return items
end
