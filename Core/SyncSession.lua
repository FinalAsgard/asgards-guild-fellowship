local _, addon = ...

-- Guild sync's conversation between add-on users.
--
-- Live edits: an officer's edit is broadcast to the guild as it happens and
-- applied by everyone who receives it.
--
-- Catching up: a while after login, a client announces the digest
-- (SyncDigest) of the officer facts it holds. Nobody needs to be an
-- officer for this, so members who never play at the same time as an
-- officer still get officers' edits through anyone who has them.
--   1. "digest": the announcement. A client whose digest matches says
--      nothing, so two clients that agree exchange one short message.
--   2. "facts" with `re` (the announcer) and `buckets`: a reply with every
--      fact the replier holds in the buckets that differ. Every client that
--      could reply waits a random short delay first, and stays silent once
--      it hears someone else's reply to the same announcement, so each
--      announcement gets one reply.
--   3. "facts": the announcer's own facts from those buckets that the reply
--      lacked or held older, so the data settles both ways.
-- Everyone applies every facts message they hear, so bystanders catch up too.
--
-- Suggestions (SuggestionService): a member's own edit stays on their side
-- and is kept as a suggestion. It's sent ("suggest") right away when an
-- officer is online, and otherwise when an officer's announcement shows one
-- has logged in. Officers queue it; the first to decide sends a "facts"
-- message with `decided` naming the suggestion (and, when approved, the new
-- officer fact), which settles it everywhere.
--
-- Every message is a table { v = PROTOCOL, t = type, ... }. A message with
-- another protocol version, or a type this version doesn't know, is ignored,
-- so mixed add-on versions in one guild never break each other.
--
-- Pure: the transport, clock and timers, and the game's facts are passed in.
--   comm         { Broadcast(message) } sending to the guild
--   context()    -> partition, normalizer for the current guild, or nil
--   selfKey()    -> the logged-in character's key, or nil
--   isOfficer(key) -> boolean
--   now()        -> server time in seconds, or nil
--   after(seconds, callback) -> false when there are no timers
--   random(low, high) -> a whole number from low to high
--   officerOnline() -> whether another character with an officer rank is
--                  online now
--   onApplied(count) called after received facts changed the roster
local SyncSession = {
    PROTOCOL = 1,
    TYPE_FACTS = "facts",
    TYPE_DIGEST = "digest",
    TYPE_SUGGEST = "suggest",
    -- The announcement goes out START_DELAY to START_DELAY + START_SPREAD
    -- seconds after login, so logging in is never slowed down and a guild
    -- logging in together doesn't announce all at once.
    START_DELAY = 30,
    START_SPREAD = 30,
    -- Before the roster has been scanned, nobody's rank is known, so the
    -- announcement waits this long and tries again.
    RETRY_SECONDS = 30,
    -- A reply waits a random REPLY_MIN to REPLY_MAX seconds.
    REPLY_MIN = 1,
    REPLY_MAX = 5,
}
addon.SyncSession = SyncSession

local Session = {}
Session.__index = Session

function SyncSession.Create(options)
    return setmetatable({
        comm = options.comm,
        context = options.context,
        selfKey = options.selfKey,
        isOfficer = options.isOfficer,
        now = options.now,
        after = options.after or function()
            return false
        end,
        random = options.random or function(low)
            return low
        end,
        officerOnline = options.officerOnline or function()
            return false
        end,
        onApplied = options.onApplied or function() end,
        -- Announcer key -> a reply this client is waiting to send.
        replies = {},
    }, Session)
end

function Session:Facts(partition)
    return addon.SyncFacts.Create(partition, {
        isOfficer = self.isOfficer,
        now = function()
            return self.now() or 0
        end,
    })
end

function Session:Send(message)
    message.v = SyncSession.PROTOCOL
    self.comm:Broadcast(message)
end

-- Runs `callback` after `seconds`, or now when there are no timers.
function Session:Later(seconds, callback)
    if not self.after(seconds, callback) then
        callback()
    end
end

-- After this user changed main links by hand: stamps the main link of every
-- character in `keys` (a set) as theirs, now, and broadcasts them when this
-- user is an officer. A member suggests only the links that changed:
-- `before` maps each key to its player's main before the edit. Returns the
-- facts sent, or nil when nothing was sent.
function Session:LocalEdit(keys, before)
    return self:StampAndSend(function(facts, author, now)
        return facts:Stamp(keys, author, now)
    end, function(fact)
        return before == nil or before[fact.character] ~= fact.main
    end)
end

-- After this user set or cleared the alias of `key`'s player by hand: the
-- same, for that player's alias.
function Session:LocalAliasEdit(key)
    return self:StampAndSend(function(facts, author, now)
        return { facts:StampAlias(key, author, now) }
    end)
end

-- Once the roster is known (after a scan): when this user is an officer,
-- their manual edits from before guild sync become official, stamped now,
-- and are broadcast. A member's older edits stay local and unstamped, so
-- they never become official or suggestions. Safe to call after every scan.
function Session:UpgradeLegacy()
    local author = self.selfKey()
    if author == nil or not self.isOfficer(author) then
        return nil
    end
    return self:StampAndSend(function(facts, officer, now)
        return facts:StampLegacy(officer, now)
    end)
end

-- Stamps with `stamp(facts, author, now)` -> list of facts, and broadcasts
-- them when this user is an officer. A member's edit stays on their side and
-- the facts `changed(fact)` accepts (all, without it) become suggestions.
function Session:StampAndSend(stamp, changed)
    local partition = self.context()
    local author = self.selfKey()
    local now = self.now()
    if partition == nil or author == nil or now == nil then
        return nil
    end
    local facts = stamp(self:Facts(partition), author, now)
    if facts[1] == nil then
        return nil
    end
    local suggestions = self:Suggestions(partition)
    if not self.isOfficer(author) then
        local suggested = {}
        local index
        for index = 1, #facts do
            if changed == nil or changed(facts[index]) then
                table.insert(suggested, facts[index])
            end
        end
        if suggested[1] ~= nil then
            suggestions:Record(suggested)
            if self.officerOnline() then
                self:SendSuggestions(partition)
            end
        end
        return nil
    end
    -- An officer's edit settles the queued suggestions it overtakes.
    suggestions:Settle(nil)
    self:Send({ t = SyncSession.TYPE_FACTS, facts = facts })
    return facts
end

-- Suggestions -----------------------------------------------------------------

function Session:Suggestions(partition)
    return addon.SuggestionService.Create(partition, {
        isOfficer = self.isOfficer,
        now = function()
            return self.now() or 0
        end,
    })
end

-- Sends this member's pending suggestions, if any, for officers online to
-- queue. They stay pending until an officer decides them.
function Session:SendSuggestions(partition)
    local pending = self:Suggestions(partition):Pending()
    if pending[1] == nil then
        return false
    end
    self:Send({ t = SyncSession.TYPE_SUGGEST, facts = pending })
    return true
end

-- This officer approves or rejects the queued suggestion about `character`
-- of `kind`. Approving makes it an officer fact under this officer's name;
-- either way the decision goes to the guild, so other officers' queues and
-- the member's pending list drop it. Returns true, or false and why not.
function Session:Decide(character, kind, approved)
    local partition = self.context()
    local officer = self.selfKey()
    local now = self.now()
    if partition == nil or officer == nil or not self.isOfficer(officer) then
        return false, "only officers can decide suggestions"
    end
    local suggestions = self:Suggestions(partition)
    local entry = suggestions:Entry(character, kind)
    if entry == nil then
        return false, "that suggestion is no longer pending"
    end
    local decided = suggestions:Decision(entry, approved)
    local facts = {}
    if approved then
        if now == nil then
            return false, "the server time isn't known"
        end
        local fact = suggestions:FactFor(entry, officer, now)
        if self:Facts(partition):ApplyAll({ fact }) == 0 then
            return false, "it can't be applied here (is the player marked Don't sync?)"
        end
        facts = { fact }
    end
    suggestions:Settle(decided)
    self:Send({ t = SyncSession.TYPE_FACTS, facts = facts, decided = decided })
    return true
end

-- Catching up -----------------------------------------------------------------

-- Called once saved data is ready (at login): schedules the announcement.
function Session:Start()
    if self.started then
        return
    end
    self.started = true
    local delay = SyncSession.START_DELAY + self.random(0, SyncSession.START_SPREAD)
    self:Later(delay, function()
        self:Announce()
    end)
end

-- Announces this client's digest, once the roster has been scanned. Returns
-- true when it was sent.
function Session:Announce()
    local partition = self.context()
    if partition == nil or not partition:HasBeenScanned() or self.selfKey() == nil then
        -- With no timers there's no waiting for the scan; the next login
        -- tries again.
        self.after(SyncSession.RETRY_SECONDS, function()
            self:Announce()
        end)
        return false
    end
    local facts = self:Facts(partition):OfficerFacts()
    self:Send({ t = SyncSession.TYPE_DIGEST, digest = addon.SyncDigest.Of(facts) })
    if not self.isOfficer(self.selfKey()) and self.officerOnline() then
        self:SendSuggestions(partition)
    end
    return true
end

-- After "Don't sync" was turned off for `key`'s player: lets officer data
-- win for it again, and asks the guild for it right away rather than at the
-- next login.
function Session:Rejoin(key)
    local partition = self.context()
    if partition == nil then
        return false
    end
    self:Facts(partition):Rejoin(key)
    return self:Announce()
end

-- Someone announced `digest`: unless it matches, schedules a reply with this
-- client's facts in the buckets that differ.
function Session:OnDigest(digest, announcer, partition)
    local digests = addon.SyncDigest
    if not digests.IsValid(digest) or self.replies[announcer] ~= nil then
        return
    end
    local mine = digests.Of(self:Facts(partition):OfficerFacts())
    local buckets = digests.Differing(mine, digest)
    if buckets[1] == nil then
        return
    end
    local reply = { buckets = buckets }
    self.replies[announcer] = reply
    self:Later(self.random(SyncSession.REPLY_MIN, SyncSession.REPLY_MAX), function()
        if self.replies[announcer] ~= reply then
            return
        end
        self.replies[announcer] = nil
        -- The guild may have changed while the reply waited.
        local current = self.context()
        if current == nil or current.key ~= partition.key then
            return
        end
        partition = current
        local facts = digests.FactsIn(self:Facts(partition):OfficerFacts(), buckets)
        self:Send({ t = SyncSession.TYPE_FACTS, re = announcer, buckets = buckets, facts = facts })
    end)
end

-- A reply to this client's announcement: sends back this client's facts in
-- those buckets that the reply lacked or held older.
function Session:FollowUp(reply, partition)
    local digests = addon.SyncDigest
    if not digests.IsBucketList(reply.buckets) or type(reply.facts) ~= "table" then
        return
    end
    local theirs = {}
    local index
    for index = 1, #reply.facts do
        local fact = reply.facts[index]
        if addon.SyncFacts.IsValid(fact) then
            theirs[fact.kind .. "\31" .. fact.character] = fact
        end
    end
    local missing = {}
    local mine = digests.FactsIn(self:Facts(partition):OfficerFacts(), reply.buckets)
    for index = 1, #mine do
        local fact = mine[index]
        local held = theirs[fact.kind .. "\31" .. fact.character]
        if held == nil or addon.SyncFacts.IsNewer(fact.at, fact.by, held.at, held.by) then
            table.insert(missing, fact)
        end
    end
    if missing[1] ~= nil then
        self:Send({ t = SyncSession.TYPE_FACTS, facts = missing })
    end
end

-- A message from `sender` (a name as the game reports it). Returns how many
-- facts it applied.
function Session:Receive(message, sender)
    if type(message) ~= "table" or message.v ~= SyncSession.PROTOCOL then
        return 0
    end
    local partition, normalizer = self.context()
    if partition == nil then
        return 0
    end
    local senderKey = normalizer:Key(sender)
    -- The game echoes guild messages back to their sender.
    local selfKey = self.selfKey()
    if senderKey == nil or senderKey == selfKey then
        return 0
    end
    local selfIsOfficer = selfKey ~= nil and self.isOfficer(selfKey)
    if message.t == SyncSession.TYPE_DIGEST then
        self:OnDigest(message.digest, senderKey, partition)
        -- An officer just logged in: time for this member's suggestions.
        if not selfIsOfficer and self.isOfficer(senderKey) then
            self:SendSuggestions(partition)
        end
        return 0
    end
    if message.t == SyncSession.TYPE_SUGGEST then
        if selfIsOfficer and self:Suggestions(partition):Queue(message.facts, senderKey) > 0 then
            self.onApplied(0)
        end
        return 0
    end
    if message.t ~= SyncSession.TYPE_FACTS then
        return 0
    end
    local applied = self:Facts(partition):ApplyAll(message.facts)
    -- Only an officer's decision settles a suggestion; newer officer facts
    -- settle the ones they overtake.
    local decided
    if addon.SuggestionService.IsDecision(message.decided) and self.isOfficer(senderKey) then
        decided = message.decided
    end
    local suggestions = self:Suggestions(partition)
    local settled = suggestions:Settle(decided) + suggestions:Prune(decided)
    if applied > 0 or settled > 0 then
        self.onApplied(applied)
    end
    if type(message.re) == "string" then
        -- Someone answered that announcement, so this client doesn't.
        self.replies[message.re] = nil
        if message.re == selfKey then
            self:FollowUp(message, partition)
        end
    end
    return applied
end
