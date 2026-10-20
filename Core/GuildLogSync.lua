local _, addon = ...

-- Sharing the officers' guild log (GuildLog) between officers' add-ons, so
-- one officer's log fills another's gaps. Messages go to officers only
-- (the caller's `send` uses the add-on officer channel), and only an
-- officer's add-on keeps or answers them, so members never receive or
-- store log entries.
--
-- Live: entries an officer's add-on records (or fills in) go out at once.
--
-- Catching up, as guild sync does (see SyncSession):
--   1. "logdigest": a while after login, an officer announces the digest
--      of their log (a checksum per month, see GuildLog:Digest). An
--      officer whose digest matches says nothing.
--   2. "logentries" with `re` (the announcer) and `months`: a reply with
--      every entry the replier holds in the months that differ, in parts
--      of ENTRIES_PER_MESSAGE, the last marked `last`. Every officer that
--      could reply waits a random short delay first, and stays silent once
--      it hears someone else's reply to the same announcement.
--   3. "logentries": once the last part arrived, the announcer's own
--      entries in those months that the reply didn't hold as they are
--      here, so the logs settle both ways.
-- Every officer merges every entries message it hears (GuildLog:Merge), so
-- bystanders catch up too, and repeats merge into the entry they repeat.
--
-- Probing: "logping" asks every officer's add-on that hears it to answer
-- "logpong", for `/agf probe officer`.
--
-- Never in the way of play: everything runs as background work on
-- `worker` (the guild sync session), within its frame budget and never
-- while the player is busy.
--
-- Pure: the transport, clock, timers and the log are passed in.
--   send(message)      sends to the guild's officers
--   probe(message)     -> whether it could send `message` to the officer
--                         channel alone, with no fallback (send, when nil)
--   log()              -> this officer's GuildLog and NameNormalizer, or
--                         nil when this character isn't an officer (or
--                         there's no guild)
--   selfKey()          -> the logged-in character's key, or nil
--   isOfficer(key)     -> boolean
--   worker             { Queue(work), Checkpoint() }
--   after(seconds, callback) -> false when there are no timers
--   random(low, high)  -> a whole number from low to high
--   onMerged(count)    called after entries from another officer changed
--                      this log
local GuildLogSync = {
    PROTOCOL = 1,
    TYPE_DIGEST = "logdigest",
    TYPE_ENTRIES = "logentries",
    TYPE_PING = "logping",
    TYPE_PONG = "logpong",
    -- After guild sync's own announcement.
    START_DELAY = 60,
    START_SPREAD = 30,
    -- Before the roster has been scanned, nobody's rank is known.
    RETRY_SECONDS = 30,
    REPLY_MIN = 1,
    REPLY_MAX = 4,
    ENTRIES_PER_MESSAGE = 50,
    -- How long `/agf probe officer` waits for answers.
    PROBE_SECONDS = 5,
}
addon.GuildLogSync = GuildLogSync

GuildLogSync.TYPES = {
    [GuildLogSync.TYPE_DIGEST] = true,
    [GuildLogSync.TYPE_ENTRIES] = true,
    [GuildLogSync.TYPE_PING] = true,
    [GuildLogSync.TYPE_PONG] = true,
}

local Sync = {}
Sync.__index = Sync

function GuildLogSync.Create(options)
    return setmetatable({
        send = options.send,
        probe = options.probe or function(message)
            options.send(message)
            return true
        end,
        log = options.log,
        selfKey = options.selfKey,
        isOfficer = options.isOfficer,
        worker = options.worker,
        after = options.after or function()
            return false
        end,
        random = options.random or function(low)
            return low
        end,
        onMerged = options.onMerged or function() end,
        -- Announcer key -> a reply this add-on is waiting to send.
        replies = {},
        -- Replier key -> the hashes of the entries it sent in reply to this
        -- add-on's announcement so far.
        received = {},
        -- Probe id -> the names of the officers whose add-ons answered.
        pings = {},
        pingCount = 0,
    }, Sync)
end

function Sync:Later(seconds, callback)
    if not self.after(seconds, callback) then
        callback()
    end
end

function Sync:checkpoint()
    return function()
        self.worker:Checkpoint()
    end
end

function Sync:Send(message)
    message.v = GuildLogSync.PROTOCOL
    self.send(message)
end

-- Sends `entries` in parts. `reply`, when given, is { re, months } and
-- marks each part as a reply, the last with `last`, even when there are no
-- entries at all.
function Sync:SendEntries(entries, reply)
    local size = GuildLogSync.ENTRIES_PER_MESSAGE
    local parts = math.max(reply ~= nil and 1 or 0, math.ceil(#entries / size))
    local part
    for part = 1, parts do
        local chunk = {}
        local entryIndex
        for entryIndex = (part - 1) * size + 1, math.min(part * size, #entries) do
            table.insert(chunk, entries[entryIndex])
        end
        local message = { t = GuildLogSync.TYPE_ENTRIES, entries = chunk }
        if reply ~= nil then
            message.re = reply.re
            message.months = reply.months
            message.last = part == parts or nil
        end
        self:Send(message)
    end
end

-- After this officer's add-on recorded or filled in `entries` (as
-- GuildLog:RecordBatch returns them): shares them with the other officers.
function Sync:Share(entries)
    if type(entries) ~= "table" or entries[1] == nil then
        return
    end
    local copies = {}
    local entryIndex
    for entryIndex = 1, #entries do
        copies[entryIndex] = addon.GuildLog.Copy(entries[entryIndex])
    end
    self.worker:Queue(function()
        if self.log() ~= nil then
            self:SendEntries(copies)
        end
    end)
end

-- Catching up -------------------------------------------------------------------

-- Called once saved data is ready (at login): schedules the announcement.
function Sync:Start()
    if self.started then
        return
    end
    self.started = true
    self:Later(GuildLogSync.START_DELAY + self.random(0, GuildLogSync.START_SPREAD), function()
        self:Announce()
    end)
end

function Sync:Announce()
    self.worker:Queue(function()
        self:SendDigest()
    end)
end

function Sync:SendDigest()
    if self.selfKey() == nil then
        self.after(GuildLogSync.RETRY_SECONDS, function()
            self:Announce()
        end)
        return
    end
    local log = self.log()
    if log == nil then
        return
    end
    self.received = {}
    self:Send({ t = GuildLogSync.TYPE_DIGEST, digest = log:Digest(self:checkpoint()) })
end

-- Another officer announced `digest`: unless it matches, schedules a reply
-- with this log's entries in the months that differ.
function Sync:OnDigest(digest, announcer, log)
    if not addon.GuildLog.IsDigest(digest) or self.replies[announcer] ~= nil then
        return
    end
    local months = addon.GuildLog.DifferingMonths(log:Digest(self:checkpoint()), digest)
    if months[1] == nil then
        return
    end
    local reply = { re = announcer, months = months }
    self.replies[announcer] = reply
    -- Messages heard meanwhile are worked through first, so a reply heard
    -- before this one's turn still silences it.
    self:Later(self.random(GuildLogSync.REPLY_MIN, GuildLogSync.REPLY_MAX), function()
        self.worker:Queue(function()
            if self.replies[announcer] ~= reply then
                return
            end
            self.replies[announcer] = nil
            local current = self.log()
            if current == nil then
                return
            end
            self:SendEntries(current:EntriesInMonths(months, self:checkpoint()), reply)
        end)
    end)
end

-- A part of a reply to this officer's announcement, from `replier`: once
-- the last part arrived, sends this log's entries in those months that the
-- reply didn't hold as they are here.
function Sync:OnReply(message, replier, log)
    local hashes = self.received[replier] or {}
    self.received[replier] = hashes
    local entryIndex
    for entryIndex = 1, #message.entries do
        local entry = addon.GuildLog.Clean(message.entries[entryIndex])
        if entry ~= nil then
            hashes[addon.GuildLog.HashOf(entry)] = true
        end
    end
    if not message.last or not addon.GuildLog.IsMonthList(message.months) then
        return
    end
    self.received[replier] = nil
    local missing = {}
    local mine = log:EntriesInMonths(message.months, self:checkpoint())
    for entryIndex = 1, #mine do
        if not hashes[addon.GuildLog.HashOf(mine[entryIndex])] then
            table.insert(missing, mine[entryIndex])
        end
    end
    if missing[1] ~= nil then
        self:SendEntries(missing)
    end
end

-- Probing ---------------------------------------------------------------------

-- Sends one ping to the officer channel alone. Returns its id, for
-- Answers, and whether it could be sent.
function Sync:Ping()
    self.pingCount = self.pingCount + 1
    local id = tostring(self.selfKey() or "") .. ":" .. self.pingCount
    self.pings[id] = {}
    local sent = self.probe({ v = GuildLogSync.PROTOCOL, t = GuildLogSync.TYPE_PING, id = id })
    return id, sent ~= false
end

-- The names (as the game reports them) of the officers whose add-ons
-- answered ping `id`, in the order they answered.
function Sync:Answers(id)
    return self.pings[id] or {}
end

-- What `/agf probe officer` prints: who answered the ping (`answers`,
-- names as the game reports them) next to who the add-on counts as an
-- officer online (`online`, a list of { key, name }), and who of those
-- didn't answer. `keyOf(name)` gives a character key.
function GuildLogSync.ProbeLines(answers, online, keyOf)
    local answered = {}
    local names = {}
    local answerIndex
    for answerIndex = 1, #answers do
        local key = keyOf(answers[answerIndex])
        if key ~= nil and not answered[key] then
            answered[key] = true
            table.insert(names, answers[answerIndex])
        end
    end
    local officers, missed = {}, {}
    local officerIndex
    for officerIndex = 1, #online do
        table.insert(officers, online[officerIndex].name)
        if not answered[online[officerIndex].key] then
            table.insert(missed, online[officerIndex].name)
        end
    end
    local function list(values)
        return values[1] ~= nil and table.concat(values, ", ") or "nobody"
    end
    return {
        "Officer channel probe:",
        "  Answered: " .. list(names),
        "  Officers online (by the add-on's officer rule): " .. list(officers),
        "  Missed by the officer channel: " .. list(missed),
    }
end

-- Receiving -------------------------------------------------------------------

-- A message from `sender` (a name as the game reports it): worked on in the
-- background, after anything heard before it.
function Sync:Receive(message, sender)
    if type(message) ~= "table" or message.v ~= GuildLogSync.PROTOCOL or not GuildLogSync.TYPES[message.t] then
        return
    end
    self.worker:Queue(function()
        self:Process(message, sender)
    end)
end

-- Works on one received message. Only an officer's add-on works on any, and
-- only on those from another officer. Returns how many entries it added.
function Sync:Process(message, sender)
    local log, normalizer = self.log()
    if log == nil then
        return 0
    end
    local senderKey = normalizer:Key(sender)
    if senderKey == nil or senderKey == self.selfKey() or not self.isOfficer(senderKey) then
        return 0
    end
    if message.t == GuildLogSync.TYPE_PING then
        if type(message.id) == "string" then
            self:Send({ t = GuildLogSync.TYPE_PONG, re = message.id })
        end
        return 0
    end
    if message.t == GuildLogSync.TYPE_PONG then
        local answers = self.pings[message.re]
        if answers ~= nil then
            table.insert(answers, sender)
        end
        return 0
    end
    if message.t == GuildLogSync.TYPE_DIGEST then
        self:OnDigest(message.digest, senderKey, log)
        return 0
    end
    if type(message.entries) ~= "table" then
        return 0
    end
    local added, changed = log:Merge(message.entries, self:checkpoint())
    if changed[1] ~= nil then
        self.onMerged(#changed)
    end
    if type(message.re) == "string" then
        -- Someone answered that announcement, so this add-on doesn't.
        self.replies[message.re] = nil
        if message.re == self.selfKey() then
            self:OnReply(message, senderKey, log)
        end
    end
    return added
end
