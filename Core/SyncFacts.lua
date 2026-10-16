local _, addon = ...

-- Guild sync's facts and the rule for applying them. A fact is one thing an
-- officer said about the roster, stamped with when (server time) and by
-- whom (a character key):
--
--   { kind = "main", character = key, main = key, at = seconds, by = key }
--   { kind = "alias", character = key, alias = text, at = seconds, by = key }
--   { kind = "declared", character = key, declared = boolean, at = seconds, by = key }
--
-- "character's main is main"; a character that is its own main says so with
-- main == character. "character's player goes by alias"; an empty alias
-- clears it. "character is (or isn't) declared its player's main": the
-- player deliberately says it's their main, even with no alts. Older
-- clients see the declared kind as malformed and ignore it.
--
-- Player profile facts are a character's own data, not officers':
--
--   { kind = "roles", character = key, roles = { role, ... }, at = seconds, by = key }
--
--   { kind = "discord"|"location"|"bio", character = key, text = text, at = seconds, by = key }
--
-- "character is willing to play roles" (tank, healer, dps; empty for
-- none), and the player's Discord username, location and bio as that
-- character last set them ("" clears one). Only the character itself can
-- write one: a profile fact is accepted only when `by` is `character`,
-- whatever the author's rank, and is never a suggestion. The one exception
-- is Discord, which an officer may also set for a guildmate: a Discord fact
-- by someone else is accepted when `by` is an officer, like officer facts
-- (and refused for a "Don't sync" player). Newest wins, as for officer
-- facts. A text field is stored on the character that wrote it (an
-- officer's on the player's main); the player's value is the newest across
-- its characters. Older
-- clients see these kinds as malformed and ignore them. Player ids are
-- local counters, so facts only ever name characters, and each client
-- rebuilds its own players from them.
--
-- Pure: works on a FellowshipStore partition and never touches the game.
local SyncFacts = {
    KIND_MAIN = "main",
    KIND_ALIAS = "alias",
    KIND_DECLARED = "declared",
    KIND_ROLES = "roles",
    KIND_DISCORD = "discord",
    KIND_LOCATION = "location",
    KIND_BIO = "bio",
    -- The same limit "Set alias…" enforces.
    MAX_ALIAS_LENGTH = 48,
    -- How far ahead of server time a fact may be dated: enough for clocks
    -- that disagree a little.
    MAX_FUTURE_SECONDS = 300,
}
-- Kinds only the character they describe may write.
SyncFacts.PROFILE_KINDS = {
    [SyncFacts.KIND_ROLES] = true,
    [SyncFacts.KIND_DISCORD] = true,
    [SyncFacts.KIND_LOCATION] = true,
    [SyncFacts.KIND_BIO] = true,
}
-- The profile kinds that carry text, each a FellowshipStore profile field
-- of the same name, in the order they're shown.
SyncFacts.TEXT_KINDS = { SyncFacts.KIND_DISCORD, SyncFacts.KIND_LOCATION, SyncFacts.KIND_BIO }
-- The profile text kinds an officer may also set for someone else.
SyncFacts.OFFICER_TEXT_KINDS = { [SyncFacts.KIND_DISCORD] = true }
addon.SyncFacts = SyncFacts

local Facts = {}
Facts.__index = Facts

local function isText(value)
    return type(value) == "string" and value ~= ""
end

local function isTimestamp(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

-- True when `fact` has the shape of a main-link, alias or roles fact.
function SyncFacts.IsValid(fact)
    if type(fact) ~= "table" or not isText(fact.character) or not isTimestamp(fact.at) or not isText(fact.by) then
        return false
    end
    if fact.kind == SyncFacts.KIND_MAIN then
        return isText(fact.main)
    end
    if fact.kind == SyncFacts.KIND_ROLES then
        return addon.FellowshipStore.IsRoleList(fact.roles)
    end
    if fact.kind == SyncFacts.KIND_DECLARED then
        return type(fact.declared) == "boolean"
    end
    if addon.FellowshipStore.PROFILE_FIELDS[fact.kind] ~= nil then
        return addon.FellowshipStore.IsProfileText(fact.kind, fact.text)
    end
    return fact.kind == SyncFacts.KIND_ALIAS
        and type(fact.alias) == "string"
        and #fact.alias <= SyncFacts.MAX_ALIAS_LENGTH
end

-- Newest wins. Two edits in the same second are settled by author, so every
-- client settles them the same way.
function SyncFacts.IsNewer(at, by, heldAt, heldBy)
    if at ~= heldAt then
        return at > heldAt
    end
    return by > (heldBy or "")
end

-- options.isOfficer(key) -> boolean, from OfficerAuthority.
-- options.now() -> timestamp, used for acting-main history dates.
function SyncFacts.Create(partition, options)
    options = options or {}
    return setmetatable({
        partition = partition,
        isOfficer = options.isOfficer or function()
            return false
        end,
        now = options.now or function()
            return 0
        end,
    }, Facts)
end

-- The main-link fact for `key` as this client holds it, or nil.
function Facts:FactOf(key)
    local character = self.partition:GetCharacter(key)
    local player = character and self.partition:GetPlayer(character.player)
    if player == nil then
        return nil
    end
    local at, by = self.partition:GetMainStamp(key)
    return {
        kind = SyncFacts.KIND_MAIN,
        character = key,
        main = player.main,
        at = at,
        by = by,
    }
end

-- The alias fact for `key`'s player as this client holds it, or nil. It
-- names the player by its main.
function Facts:AliasFactOf(key)
    local character = self.partition:GetCharacter(key)
    local player = character and self.partition:GetPlayer(character.player)
    if player == nil then
        return nil
    end
    local at, by = self.partition:GetAliasStamp(key)
    return {
        kind = SyncFacts.KIND_ALIAS,
        character = player.main,
        alias = player.alias or "",
        at = at,
        by = by,
    }
end

-- The declared-main fact for `key` as this client holds it, or nil for an
-- unknown character.
function Facts:DeclaredFactOf(key)
    local at, by = self.partition:GetDeclaredStamp(key)
    if at == nil then
        return nil
    end
    return {
        kind = SyncFacts.KIND_DECLARED,
        character = key,
        declared = self.partition:IsDeclared(key),
        at = at,
        by = by,
    }
end

-- Stamps whether `key` is declared a main as set by `author` at `at`
-- (always newer than the stamp it replaces), and returns its fact, or nil
-- for an unknown character.
function Facts:StampDeclared(key, author, at)
    local heldAt = self.partition:GetDeclaredStamp(key)
    if heldAt == nil then
        return nil
    end
    self.partition:SetDeclaredStamp(key, math.max(at, heldAt + 1), author)
    return self:DeclaredFactOf(key)
end

-- Stamps the current alias of `key`'s player as set by `author` at `at`
-- (always newer than the stamp it replaces), and returns its fact, or nil
-- for an unknown character.
function Facts:StampAlias(key, author, at)
    local heldAt = self.partition:GetAliasStamp(key)
    if heldAt == nil then
        return nil
    end
    self.partition:SetAliasStamp(key, math.max(at, heldAt + 1), author)
    return self:AliasFactOf(key)
end

-- Upgrading from before guild sync: every manual main link and alias that
-- was never stamped is stamped as `author`'s, at `at`, and returned as facts
-- (main links sorted by character, then aliases sorted by main). Edits made
-- since sync shipped are always stamped, so only older ones are found, and
-- running this again finds nothing. Note- and roster-seeded facts stay
-- unstamped: the oldest possible.
function Facts:StampLegacy(author, at)
    local partition = self.partition
    local manual = addon.FellowshipStore.SOURCE_MANUAL
    local links, aliases = {}, {}
    partition:EachCharacter(function(key, character)
        if character.source == manual and character.mainAt == nil then
            table.insert(links, key)
        end
    end)
    partition:EachPlayer(function(_, player)
        if player.aliasSource == manual and player.aliasAt == nil then
            table.insert(aliases, player.main)
        end
    end)
    table.sort(links)
    table.sort(aliases)
    local facts = {}
    local index
    for index = 1, #links do
        partition:SetMainStamp(links[index], at, author)
        table.insert(facts, self:FactOf(links[index]))
    end
    for index = 1, #aliases do
        partition:SetAliasStamp(aliases[index], at, author)
        table.insert(facts, self:AliasFactOf(aliases[index]))
    end
    return facts
end

-- The roles fact for `key` as this client holds it, or nil when its role
-- preferences were never set.
function Facts:RolesFactOf(key)
    local roles = self.partition:GetRoles(key)
    if roles == nil then
        return nil
    end
    local at, by = self.partition:GetRolesStamp(key)
    return { kind = SyncFacts.KIND_ROLES, character = key, roles = roles, at = at, by = by }
end

-- Sets `key`'s role preferences to `roles`, written by the character
-- itself at `at` (always newer than the stamp it replaces), and returns its
-- fact, or nil for an unknown character or unusable roles.
function Facts:StampRoles(key, roles, at)
    local heldAt = self.partition:GetRolesStamp(key)
    if heldAt == nil
        or not self.partition:SetRoles(key, addon.RoleCatalog.Ordered(roles), math.max(at, heldAt + 1), key)
    then
        return nil
    end
    return self:RolesFactOf(key)
end

-- The `kind` text fact ("discord", "location" or "bio") for `key` as this
-- client holds it, or nil when that character never set it.
function Facts:TextFactOf(key, kind)
    local text = self.partition:GetProfileText(key, kind)
    if text == nil then
        return nil
    end
    local at, by = self.partition:GetProfileStamp(key, kind)
    return { kind = kind, character = key, text = text, at = at, by = by }
end

-- The profile fact of `kind` for `key` as this client holds it, or nil.
function Facts:ProfileFactOf(key, kind)
    if kind == SyncFacts.KIND_ROLES then
        return self:RolesFactOf(key)
    end
    return self:TextFactOf(key, kind)
end

-- Sets `key`'s `kind` text to `text` ("" clears it), written by `author`
-- (the character itself, without it) at `at`, and returns its fact, or nil
-- for an unknown character or unusable text. The stamp is newer than any of
-- the player's characters' for that field, so the player's value becomes
-- this one.
function Facts:StampText(key, kind, text, at, author)
    author = author or key
    local character = self.partition:GetCharacter(key)
    if character == nil then
        return nil
    end
    local _, newestAt = self.partition:PlayerProfileText(character.player, kind)
    local heldAt = self.partition:GetProfileStamp(key, kind) or 0
    if not self.partition:SetProfileText(key, kind, text, math.max(at, heldAt + 1, (newestAt or 0) + 1), author) then
        return nil
    end
    return self:TextFactOf(key, kind)
end

-- When the thing `fact` is about was last set, and by whom, or nil when the
-- character is unknown.
function Facts:HeldStamp(fact)
    if fact.kind == SyncFacts.KIND_ROLES then
        return self.partition:GetRolesStamp(fact.character)
    end
    if addon.FellowshipStore.PROFILE_FIELDS[fact.kind] ~= nil then
        return self.partition:GetProfileStamp(fact.character, fact.kind)
    end
    if fact.kind == SyncFacts.KIND_ALIAS then
        return self.partition:GetAliasStamp(fact.character)
    end
    if fact.kind == SyncFacts.KIND_DECLARED then
        return self.partition:GetDeclaredStamp(fact.character)
    end
    return self.partition:GetMainStamp(fact.character)
end

-- Stamps the current main link of every key in `keys` (a set) as set by
-- `author` at `at`, and returns those facts sorted by character. A stamp is
-- always newer than the one it replaces, so a second edit within the same
-- second still wins everywhere.
function Facts:Stamp(keys, author, at)
    local sorted = {}
    local key
    for key in pairs(keys) do
        if self.partition:GetCharacter(key) ~= nil then
            table.insert(sorted, key)
        end
    end
    table.sort(sorted)
    local facts = {}
    local index
    for index = 1, #sorted do
        local heldAt = self.partition:GetMainStamp(sorted[index])
        self.partition:SetMainStamp(sorted[index], math.max(at, heldAt + 1), author)
        table.insert(facts, self:FactOf(sorted[index]))
    end
    return facts
end

-- Whether a received fact should be applied: nil when it should, or why
-- not. Any add-on user may pass officer facts on, so who sent it doesn't
-- matter: its named author must hold an officer rank on the current roster,
-- and it can't be dated more than MAX_FUTURE_SECONDS ahead of server time
-- (a fact dated far ahead would beat every real edit until then). Without a
-- known clock, the date can't be judged and isn't checked.
function Facts:Refusal(fact)
    if not SyncFacts.IsValid(fact) then
        return "malformed"
    end
    if SyncFacts.PROFILE_KINDS[fact.kind] then
        return self:ProfileRefusal(fact)
    end
    if not self.isOfficer(fact.by) then
        return "not an officer"
    end
    local now = self.now()
    if now > 0 and fact.at > now + SyncFacts.MAX_FUTURE_SECONDS then
        return "from the future"
    end
    if self.partition:GetCharacter(fact.character) == nil
        or (fact.kind == SyncFacts.KIND_MAIN and self.partition:GetCharacter(fact.main) == nil)
    then
        return "unknown character"
    end
    -- A fact that would change a "Don't sync" player, by moving one of its
    -- characters out, another in, or renaming it.
    if self:IsPinned(fact.character) or (fact.kind == SyncFacts.KIND_MAIN and self:IsPinned(fact.main)) then
        return "don't sync"
    end
    local heldAt, heldBy = self:HeldStamp(fact)
    if not SyncFacts.IsNewer(fact.at, fact.by, heldAt, heldBy) then
        return "not newer"
    end
    return nil
end

-- Refusal for a valid profile fact: only the character itself may write
-- one, or an officer a Discord username. "Don't sync" is about officers'
-- data, so it applies only to an officer's.
function Facts:ProfileRefusal(fact)
    local own = fact.by == fact.character
    if not own and not SyncFacts.OFFICER_TEXT_KINDS[fact.kind] then
        return "not the character's own"
    end
    if not own and not self.isOfficer(fact.by) then
        return "not an officer"
    end
    local now = self.now()
    if now > 0 and fact.at > now + SyncFacts.MAX_FUTURE_SECONDS then
        return "from the future"
    end
    if self.partition:GetCharacter(fact.character) == nil then
        return "unknown character"
    end
    if not own and self:IsPinned(fact.character) then
        return "don't sync"
    end
    local heldAt, heldBy = self:HeldStamp(fact)
    if not SyncFacts.IsNewer(fact.at, fact.by, heldAt, heldBy) then
        return "not newer"
    end
    return nil
end

-- Makes the roster agree with `fact`'s value, marking what changed as from
-- `source`; stamps are left alone. The notes it concerns are read again by
-- the next scan: one that now disagrees goes to the conflict queue, and a
-- pending conflict the change settled is dropped.
function Facts:Reshape(fact, source)
    local partition = self.partition
    local character = partition:GetCharacter(fact.character)
    if fact.kind == SyncFacts.KIND_ALIAS then
        if fact.alias == "" then
            partition:ClearAlias(character.player, source)
        else
            partition:SetAlias(character.player, fact.alias, source)
        end
        -- Any of the player's characters can name its alias in a note.
        local keys = partition:CharactersOf(character.player)
        local index
        for index = 1, #keys do
            partition:ForgetNoteFingerprint(keys[index])
        end
        return
    end
    partition:ForgetNoteFingerprint(fact.character)
    if fact.main == fact.character then
        -- It's a main. As an alt it leaves for a player of its own; its
        -- former player's characters follow with their own facts.
        if partition:GetPlayer(character.player).main ~= fact.character then
            partition:MoveToNewPlayer(fact.character, source)
        end
    else
        partition:JoinPlayerOf(fact.character, fact.main, source)
        local main = partition:GetCharacter(fact.main)
        if partition:GetPlayer(main.player).main ~= fact.main then
            partition:SetMain(main.player, fact.main)
        end
    end
    partition:GetCharacter(fact.character).source = source
end

-- Makes the roster agree with one accepted fact. Officer data beats guild
-- notes.
function Facts:Change(fact)
    if fact.kind == SyncFacts.KIND_ROLES then
        self.partition:SetRoles(fact.character, fact.roles, fact.at, fact.by)
        return
    end
    if addon.FellowshipStore.PROFILE_FIELDS[fact.kind] ~= nil then
        self.partition:SetProfileText(fact.character, fact.kind, fact.text, fact.at, fact.by)
        return
    end
    if fact.kind == SyncFacts.KIND_DECLARED then
        self.partition:SetDeclared(fact.character, fact.declared, addon.FellowshipStore.SOURCE_SYNC)
        self.partition:SetDeclaredStamp(fact.character, fact.at, fact.by)
        self.partition:ForgetNoteFingerprint(fact.character)
        return
    end
    self:Reshape(fact, addon.FellowshipStore.SOURCE_SYNC)
    if fact.kind == SyncFacts.KIND_ALIAS then
        self.partition:SetAliasStamp(fact.character, fact.at, fact.by)
    else
        self.partition:SetMainStamp(fact.character, fact.at, fact.by)
    end
end

-- Undoes this user's own edit: makes the roster agree with `value` (a fact
-- without a stamp: an officer's view of that thing) as if notes or the
-- roster had set it, so it is the oldest possible again and officer data
-- wins over it. Returns false when it can't be applied here.
function Facts:Restore(value)
    local fact = {
        kind = type(value) == "table" and value.kind,
        character = type(value) == "table" and value.character,
        main = type(value) == "table" and value.main,
        alias = type(value) == "table" and value.alias,
        declared = type(value) == "table" and value.declared,
        text = type(value) == "table" and value.text,
        at = 1,
        by = "?",
    }
    if not SyncFacts.IsValid(fact) or self.partition:GetCharacter(fact.character) == nil
        or (fact.kind == SyncFacts.KIND_MAIN and self.partition:GetCharacter(fact.main) == nil)
        or self:IsPinned(fact.character) or (fact.kind == SyncFacts.KIND_MAIN and self:IsPinned(fact.main))
    then
        return false
    end
    local store = addon.FellowshipStore
    if fact.kind == SyncFacts.KIND_DISCORD then
        -- Stamped the oldest possible, so the player's own and officers'
        -- values win over it.
        return self.partition:SetProfileText(fact.character, fact.kind, fact.text, 1, "?")
    end
    if fact.kind == SyncFacts.KIND_DECLARED then
        self.partition:SetDeclared(fact.character, fact.declared, store.SOURCE_NOTE)
        self.partition:ClearDeclaredStamp(fact.character)
        return true
    end
    if fact.kind == SyncFacts.KIND_ALIAS then
        self:Reshape(fact, store.SOURCE_NOTE)
        self.partition:ClearAliasStamp(fact.character)
    else
        self:Reshape(fact, fact.main == fact.character and store.SOURCE_ROSTER or store.SOURCE_NOTE)
        self.partition:ClearMainStamp(fact.character)
    end
    addon.ReconcileEngine.EnsureActingMains(self.partition, {}, self.now())
    return true
end

-- True when `key`'s player is marked "Don't sync" on this client.
function Facts:IsPinned(key)
    local character = self.partition:GetCharacter(key)
    return character ~= nil and self.partition:IsNoSync(character.player)
end

-- Every officer fact this client holds, which it can pass on to others:
-- main links, sorted by character, then aliases, sorted by main, then
-- declared mains, sorted by character. Facts
-- nobody stamped, and edits by authors who aren't officers now, aren't
-- officer data, and "Don't sync" players are this client's own business.
-- `checkpoint`, when given, is called after each character and player so a
-- scheduler can spread the work across frames.
function Facts:OfficerFacts(checkpoint)
    checkpoint = checkpoint or function() end
    local partition = self.partition
    local links, aliases, declared = {}, {}, {}
    partition:EachCharacter(function(key, character)
        if character.mainAt ~= nil and self.isOfficer(character.mainBy)
            and not partition:IsNoSync(character.player)
        then
            table.insert(links, key)
        end
        if character.declaredAt ~= nil and self.isOfficer(character.declaredBy)
            and not partition:IsNoSync(character.player)
        then
            table.insert(declared, key)
        end
    end)
    partition:EachPlayer(function(id, player)
        if player.aliasAt ~= nil and self.isOfficer(player.aliasBy) and not partition:IsNoSync(id) then
            table.insert(aliases, player.main)
        end
    end)
    table.sort(links)
    table.sort(aliases)
    table.sort(declared)
    local facts = {}
    local index
    for index = 1, #links do
        table.insert(facts, self:FactOf(links[index]))
        checkpoint()
    end
    for index = 1, #aliases do
        table.insert(facts, self:AliasFactOf(aliases[index]))
        checkpoint()
    end
    for index = 1, #declared do
        table.insert(facts, self:DeclaredFactOf(declared[index]))
        checkpoint()
    end
    return facts
end

-- Every profile fact this client holds, which it can pass on to others:
-- each character's own role preferences and profile text, and Discord
-- usernames officers set (except for "Don't sync" players), sorted by
-- character (roles, then Discord, location and bio). `checkpoint` as for
-- OfficerFacts.
function Facts:ProfileFacts(checkpoint)
    checkpoint = checkpoint or function() end
    local keys = {}
    self.partition:EachCharacter(function(key)
        table.insert(keys, key)
    end)
    table.sort(keys)
    local facts = {}
    local index, kindIndex
    for index = 1, #keys do
        local key = keys[index]
        local character = self.partition:GetCharacter(key)
        if character.rolesAt ~= nil and character.rolesBy == key and character.roles ~= nil then
            table.insert(facts, self:RolesFactOf(key))
        end
        for kindIndex = 1, #SyncFacts.TEXT_KINDS do
            local kind = SyncFacts.TEXT_KINDS[kindIndex]
            local by = character[kind .. "By"]
            local officers = SyncFacts.OFFICER_TEXT_KINDS[kind] and by ~= nil and self.isOfficer(by)
                and not self.partition:IsNoSync(character.player)
            if character[kind] ~= nil and character[kind .. "At"] ~= nil and (by == key or officers) then
                table.insert(facts, self:TextFactOf(key, kind))
            end
        end
        checkpoint()
    end
    return facts
end

-- Everything guild sync compares and passes on: officer facts, then
-- profile facts.
function Facts:SharedFacts(checkpoint)
    local facts = self:OfficerFacts(checkpoint)
    local profile = self:ProfileFacts(checkpoint)
    local index
    for index = 1, #profile do
        table.insert(facts, profile[index])
    end
    return facts
end

-- After "Don't sync" is turned off for `key`'s player: this user's own
-- stamped edits to it (not an officer's) become the oldest possible, so the
-- officers' data for it wins again when it next arrives.
function Facts:Rejoin(key)
    local partition = self.partition
    local character = partition:GetCharacter(key)
    if character == nil then
        return
    end
    local keys = partition:CharactersOf(character.player)
    local index
    for index = 1, #keys do
        local _, by = partition:GetMainStamp(keys[index])
        if by ~= nil and not self.isOfficer(by) then
            partition:ClearMainStamp(keys[index])
        end
    end
    local _, aliasBy = partition:GetAliasStamp(key)
    if aliasBy ~= nil and not self.isOfficer(aliasBy) then
        partition:ClearAliasStamp(key)
    end
    for index = 1, #keys do
        local _, declaredBy = partition:GetDeclaredStamp(keys[index])
        if declaredBy ~= nil and not self.isOfficer(declaredBy) then
            partition:ClearDeclaredStamp(keys[index])
        end
    end
end

-- Applies every acceptable fact in `facts`, then restores the acting-main
-- invariant once. Returns how many were applied. `checkpoint`, when given,
-- is called after each fact so a scheduler can spread the work across
-- frames; each fact is judged against the roster as it is by then.
function Facts:ApplyAll(facts, checkpoint)
    if type(facts) ~= "table" then
        return 0
    end
    checkpoint = checkpoint or function() end
    local applied = 0
    local index
    for index = 1, #facts do
        if self:Refusal(facts[index]) == nil then
            self:Change(facts[index])
            applied = applied + 1
        end
        checkpoint()
    end
    if applied > 0 then
        addon.ReconcileEngine.EnsureActingMains(self.partition, {}, self.now(), checkpoint)
    end
    return applied
end
