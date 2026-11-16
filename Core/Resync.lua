local _, addon = ...

-- "/agf resync <name>": copies an officer's whole view of the roster's
-- structure (main links, aliases, declared mains, Discord, location and
-- bio) over this client's, whatever the stamps held here, for when this
-- client's data went wrong and guild sync's newest-wins rule keeps it so.
--
--   1. The user names a player (a character's name or an alias). One of
--      that player's characters must be online with an officer rank; this
--      add-on whispers it "resync-ask".
--   2. The officer's add-on answers each guildmate at most once per
--      ANSWER_GAP_SECONDS: a "resync-status" at once, then "resync-data"
--      with its snapshot (SyncFacts:ResyncSnapshot, packed small by Pack),
--      and a "resync-status" with the share sent every STATUS_STEP percent.
--      The game sends a big whisper a piece at a time, so a big guild's
--      roster takes a minute or two. The officer is told to stay online,
--      and when it's done.
--   3. This add-on shows the progress, and applies the data
--      (SyncFacts:Overwrite) when it's the answer it's waiting for and that
--      character is still an officer. It gives up when nothing was heard
--      for ANSWER_SECONDS after asking, or STALL_SECONDS after the last
--      progress.
-- Membership dates, roles and the user's own profile text are left alone.
--
-- Pure: messaging, the roster, timers and the clock are handed in.
--   context()      -> partition, normalizer for the current guild, or nil
--   selfKey()      -> the logged-in character's key, or nil
--   isOfficer(key) -> true for an officer
--   isOwn(key)     -> true for the user's own characters
--   online()       -> { [key] = name } of guildmates online now, names as
--                     the game reports them
--   now()          -> seconds, or nil
--   after(seconds, callback) -> false when there are no timers
--   whisper(message, name, options) -> true when sent; options.priority
--                     (Comm's), options.onProgress(sent, total)
--   print(text)    a line in the user's own chat frame
--   onApplied(changed)  called after a resync changed the roster
local Resync = {
    PROTOCOL = 1,
    -- { v, t = TYPE_ASK }: send me your roster data.
    TYPE_ASK = "resync-ask",
    -- { v, t = TYPE_STATUS, p = percent sent }
    TYPE_STATUS = "resync-status",
    -- { v, t = TYPE_DATA, s = packed snapshot (see Pack) }
    TYPE_DATA = "resync-data",
    -- The roster goes ahead of sync's own traffic; progress ahead of that.
    PRIORITY_DATA = "NORMAL",
    PRIORITY_STATUS = "ALERT",
    STATUS_STEP = 20,
    ANSWER_SECONDS = 30,
    STALL_SECONDS = 90,
    ANSWER_GAP_SECONDS = 60,
}
addon.Resync = Resync

Resync.TYPES = {
    [Resync.TYPE_ASK] = "OnAsk",
    [Resync.TYPE_STATUS] = "OnStatus",
    [Resync.TYPE_DATA] = "OnData",
}

-- Packing -----------------------------------------------------------------------

local function isText(value)
    return type(value) == "string" and value ~= ""
end

-- `snapshot` (SyncFacts:ResyncSnapshot) as small as it travels: the game
-- sends a big whisper a piece at a time, so every byte counts. Characters
-- are grouped by player in one string, the sender's realm suffix
-- (`suffix`, e.g. "-area52") is left off keys, authors are listed once,
-- times count from the earliest, and anything at its default is left out.
-- Names never hold "," ";" or ":", so they separate the parts.
--   x = suffix, z = the earliest time, a = "author,author,..."
--   g = "main[:time:author][;alt[:time:author]]...,..." one group per
--       player, its main first, then its alts
--   s = { main, alias, time, author, set through, ... } players with an
--       alias or an alias stamp
--   d = "key:1 or 0:time:author,..." declared mains and declaration stamps
--   p = { key, kind index (SyncFacts.TEXT_KINDS), text, time, author, ... }
-- A time or author left empty (or 0 in `s` and `p`) is none; authors are
-- 1-based indexes into `a`.
function Resync.Pack(snapshot, suffix)
    suffix = type(suffix) == "string" and suffix or ""
    local function short(key)
        if suffix ~= "" and #key > #suffix and string.sub(key, -#suffix) == suffix then
            return string.sub(key, 1, -#suffix - 1)
        end
        return key
    end
    local base
    local function noteTime(at)
        if type(at) == "number" and at > 0 and (base == nil or at < base) then
            base = at
        end
    end
    local index
    for index = 1, #snapshot.l do
        noteTime(snapshot.l[index][3])
    end
    for index = 1, #snapshot.a do
        noteTime(snapshot.a[index][3])
    end
    for index = 1, #snapshot.d do
        noteTime(snapshot.d[index][3])
    end
    for index = 1, #snapshot.p do
        noteTime(snapshot.p[index][4])
    end
    base = base or 0
    local authors, authorIndex = {}, {}
    local function author(by)
        if not isText(by) then
            return 0
        end
        if authorIndex[by] == nil then
            table.insert(authors, by)
            authorIndex[by] = #authors
        end
        return authorIndex[by]
    end
    local function time(at)
        return (type(at) == "number" and at > 0) and (at - base) or nil
    end
    -- "key" or "key:time:author".
    local function stamped(key, at, by)
        local offset = time(at)
        if offset == nil then
            return short(key)
        end
        return short(key) .. ":" .. offset .. ":" .. author(by)
    end
    local groups, order = {}, {}
    local function group(main)
        if groups[main] == nil then
            groups[main] = { head = short(main), alts = {} }
            table.insert(order, main)
        end
        return groups[main]
    end
    for index = 1, #snapshot.l do
        local key, main, at, by = snapshot.l[index][1], snapshot.l[index][2], snapshot.l[index][3], snapshot.l[index][4]
        local entry = group(main)
        if key == main then
            entry.head = stamped(key, at, by)
        else
            table.insert(entry.alts, stamped(key, at, by))
        end
    end
    local parts = {}
    for index = 1, #order do
        local entry = groups[order[index]]
        local text = entry.head
        if entry.alts[1] ~= nil then
            text = text .. ";" .. table.concat(entry.alts, ";")
        end
        table.insert(parts, text)
    end
    local packed = { x = suffix, z = base, g = table.concat(parts, ","), s = {}, p = {} }
    for index = 1, #snapshot.a do
        local main, alias, at, by, through = snapshot.a[index][1], snapshot.a[index][2], snapshot.a[index][3],
            snapshot.a[index][4], snapshot.a[index][5]
        if alias ~= "" or time(at) ~= nil then
            table.insert(packed.s, short(main))
            table.insert(packed.s, alias)
            table.insert(packed.s, time(at) or 0)
            table.insert(packed.s, author(by))
            table.insert(packed.s, (isText(through) and through ~= main) and short(through) or "")
        end
    end
    local declared = {}
    for index = 1, #snapshot.d do
        local entry = snapshot.d[index]
        table.insert(declared, short(entry[1]) .. ":" .. (entry[2] and 1 or 0) .. ":" .. (time(entry[3]) or "")
            .. ":" .. (time(entry[3]) and author(entry[4]) or ""))
    end
    packed.d = table.concat(declared, ",")
    local kinds = {}
    for index = 1, #addon.SyncFacts.TEXT_KINDS do
        kinds[addon.SyncFacts.TEXT_KINDS[index]] = index
    end
    for index = 1, #snapshot.p do
        local entry = snapshot.p[index]
        if kinds[entry[2]] ~= nil then
            table.insert(packed.p, short(entry[1]))
            table.insert(packed.p, kinds[entry[2]])
            table.insert(packed.p, entry[3])
            table.insert(packed.p, time(entry[4]) or 0)
            table.insert(packed.p, author(entry[5]))
        end
    end
    packed.a = table.concat(authors, ",")
    return packed
end

-- Splits `text` at each `separator` (one character), keeping empty parts.
local function split(text, separator)
    local parts = {}
    if text == "" then
        return parts
    end
    local start = 1
    while true do
        local at = string.find(text, separator, start, true)
        if at == nil then
            table.insert(parts, string.sub(text, start))
            return parts
        end
        table.insert(parts, string.sub(text, start, at - 1))
        start = at + 1
    end
end

-- The snapshot `packed` (from Pack) holds, for SyncFacts:Overwrite, or nil
-- when it isn't one. Unreadable entries are left out.
function Resync.Unpack(packed)
    if type(packed) ~= "table" or type(packed.g) ~= "string" or type(packed.a) ~= "string" then
        return nil
    end
    local suffix = type(packed.x) == "string" and packed.x or ""
    local base = type(packed.z) == "number" and packed.z or 0
    local authors = split(packed.a, ",")
    local function full(key)
        if not isText(key) then
            return nil
        end
        if suffix ~= "" and not string.find(key, "-", 1, true) then
            return key .. suffix
        end
        return key
    end
    local function author(index)
        local by = authors[tonumber(index) or 0]
        return isText(by) and by or ""
    end
    local function time(offset)
        offset = tonumber(offset)
        if offset == nil then
            return 0
        end
        return base + offset
    end
    -- A "key[:time:author]" part: key, at, by.
    local function stamped(part)
        local fields = split(part, ":")
        local key = full(fields[1])
        if key == nil then
            return nil
        end
        if fields[2] == nil or fields[2] == "" then
            return key, 0, ""
        end
        return key, time(fields[2]), author(fields[3])
    end
    local snapshot = { l = {}, a = {}, d = {}, p = {} }
    local aliases = {}
    local groups = split(packed.g, ",")
    local index
    for index = 1, #groups do
        local members = split(groups[index], ";")
        local main, at, by = stamped(members[1] or "")
        if main ~= nil then
            table.insert(snapshot.l, { main, main, at, by })
            local member
            for member = 2, #members do
                local alt, altAt, altBy = stamped(members[member])
                if alt ~= nil then
                    table.insert(snapshot.l, { alt, main, altAt, altBy })
                end
            end
            local entry = { main, "", 0, "", main }
            table.insert(snapshot.a, entry)
            aliases[main] = entry
        end
    end
    local list = type(packed.s) == "table" and packed.s or {}
    for index = 1, #list - 4, 5 do
        local entry = aliases[full(list[index]) or ""]
        if entry ~= nil and type(list[index + 1]) == "string" then
            entry[2] = list[index + 1]
            -- Stamped when it has an author.
            if list[index + 3] ~= 0 and author(list[index + 3]) ~= "" then
                entry[3] = time(list[index + 2])
                entry[4] = author(list[index + 3])
            end
            entry[5] = full(list[index + 4]) or entry[1]
        end
    end
    local declared = split(type(packed.d) == "string" and packed.d or "", ",")
    for index = 1, #declared do
        local fields = split(declared[index], ":")
        local key = full(fields[1])
        if key ~= nil and (fields[2] == "1" or fields[2] == "0") then
            local at = (fields[3] ~= nil and fields[3] ~= "") and time(fields[3]) or 0
            table.insert(snapshot.d, { key, fields[2] == "1", at, at ~= 0 and author(fields[4]) or "" })
        end
    end
    local texts = type(packed.p) == "table" and packed.p or {}
    for index = 1, #texts - 4, 5 do
        local key = full(texts[index])
        local kind = type(texts[index + 1]) == "number" and addon.SyncFacts.TEXT_KINDS[texts[index + 1]] or nil
        if key ~= nil and kind ~= nil and type(texts[index + 2]) == "string" then
            local at = author(texts[index + 4]) ~= "" and time(texts[index + 3]) or 0
            table.insert(snapshot.p, { key, kind, texts[index + 2], at, at ~= 0 and author(texts[index + 4]) or "" })
        end
    end
    return snapshot
end

-- Sessions ----------------------------------------------------------------------

local Session = {}
Session.__index = Session

function Resync.Create(options)
    local function option(name, fallback)
        return type(options[name]) == "function" and options[name] or fallback
    end
    local function none()
        return nil
    end
    return setmetatable({
        context = option("context", none),
        selfKey = option("selfKey", none),
        isOfficer = option("isOfficer", function()
            return false
        end),
        isOwn = option("isOwn", function()
            return false
        end),
        online = option("online", function()
            return {}
        end),
        now = option("now", none),
        after = option("after", function()
            return false
        end),
        whisper = option("whisper", function()
            return false
        end),
        print = option("print", function() end),
        onApplied = option("onApplied", function() end),
        -- The officer asked: { key, name, deadline, heard, startedAt,
        -- percent }.
        pending = nil,
        -- When this officer last answered each guildmate.
        answered = {},
    }, Session)
end

local function ask(callback, ...)
    local ok, value, second = pcall(callback, ...)
    if ok then
        return value, second
    end
    return nil
end

function Session:facts(partition)
    return addon.SyncFacts.Create(partition, {
        isOfficer = function(key)
            return ask(self.isOfficer, key) == true
        end,
        now = function()
            return ask(self.now) or 0
        end,
    })
end

-- The player `name` means: a character's name, else an alias (ignoring
-- case). Returns the player id, or nil.
local function playerNamed(partition, normalizer, name)
    local key = normalizer:Key(name)
    local character = key and partition:GetCharacter(key)
    if character ~= nil then
        return character.player
    end
    local wanted = addon.NameNormalizer.Fold(name)
    local found
    partition:EachPlayer(function(id, player)
        if found == nil and type(player.alias) == "string" and addon.NameNormalizer.Fold(player.alias) == wanted then
            found = id
        end
    end)
    return found
end

-- Gives up on `pending` once its deadline passes with nothing new heard.
function Session:watch(pending)
    local now = ask(self.now)
    if type(now) ~= "number" then
        return
    end
    local function check()
        if self.pending ~= pending then
            return
        end
        local later = ask(self.now)
        if type(later) == "number" and later < pending.deadline then
            self:watch(pending)
            return
        end
        self.pending = nil
        if pending.heard then
            pcall(self.print, "Lost contact with " .. pending.name .. " before their roster data arrived, so nothing "
                .. "changed. Try /agf resync again once they're back online.")
        else
            pcall(self.print, pending.name .. "'s add-on didn't answer, so nothing changed. They may need to update "
                .. "the add-on, or be in combat; try again in a bit.")
        end
    end
    ask(self.after, math.max(pending.deadline - now, 1), check)
end

-- Asks the officer playing `name` (a character's name or alias) for their
-- roster data. Returns true, or nil, with a line for the user either way.
function Session:Ask(name)
    local partition, normalizer = ask(self.context)
    local now = ask(self.now)
    if partition == nil or normalizer == nil or type(now) ~= "number" then
        return nil, "You need to be in a guild, with its roster loaded, to resync."
    end
    if type(name) ~= "string" or string.find(name, "%S") == nil then
        return nil, "Name an officer to copy roster data from: /agf resync <name>."
    end
    if self.pending ~= nil then
        return nil, "Already resyncing from " .. self.pending.name .. "; wait for it to finish."
    end
    name = string.match(name, "^%s*(.-)%s*$")
    local player = playerNamed(partition, normalizer, name)
    if player == nil then
        return nil, "Nobody in the guild is called " .. name .. "."
    end
    local online = ask(self.online) or {}
    local keys = partition:CharactersOf(player)
    -- The user's own characters are skipped: a roster gone wrong can hold
    -- them in the officer's player.
    local target, anyOnline, ownOnline
    local index
    for index = 1, #keys do
        local key = keys[index]
        if online[key] ~= nil then
            if ask(self.isOwn, key) == true then
                ownOnline = true
            else
                anyOnline = true
                if target == nil and ask(self.isOfficer, key) == true then
                    target = { key = key, name = online[key] }
                end
            end
        end
    end
    if not anyOnline and ownOnline then
        return nil, "That's you: name another officer."
    end
    if not anyOnline then
        return nil, name .. " isn't online. Resync from an officer who is."
    end
    if target == nil then
        return nil, name .. " isn't an officer. Only an officer's roster data can be copied."
    end
    if ask(self.whisper, { v = Resync.PROTOCOL, t = Resync.TYPE_ASK }, target.name,
        { priority = Resync.PRIORITY_STATUS }) ~= true
    then
        return nil, "The request to " .. target.name .. " couldn't be sent."
    end
    self.pending = {
        key = target.key, name = target.name, deadline = now + Resync.ANSWER_SECONDS, heard = false, percent = 0,
    }
    self:watch(self.pending)
    return true, "Asked " .. target.name .. " for their roster data. You'll see its progress here; a big guild's "
        .. "takes a minute or two."
end

-- The sender's key, when they're a current guild member other than the
-- user, or nil.
function Session:senderKey(sender, partition, normalizer)
    local key = type(sender) == "string" and normalizer:Key(sender) or nil
    if key == nil or not partition:IsInGuild(key) or ask(self.isOwn, key) == true then
        return nil
    end
    return key
end

-- A guildmate's "resync-ask": an officer's add-on sends its roster, at most
-- once per ANSWER_GAP_SECONDS per guildmate, telling them how it's going and
-- the officer to stay online. Returns true when it answered.
function Session:OnAsk(message, sender)
    local partition, normalizer = ask(self.context)
    local selfKey, now = ask(self.selfKey), ask(self.now)
    if type(message) ~= "table" or message.v ~= Resync.PROTOCOL or partition == nil or normalizer == nil
        or selfKey == nil or type(now) ~= "number" or ask(self.isOfficer, selfKey) ~= true
    then
        return false
    end
    local key = self:senderKey(sender, partition, normalizer)
    if key == nil or (self.answered[key] ~= nil and now - self.answered[key] < Resync.ANSWER_GAP_SECONDS) then
        return false
    end
    self.answered[key] = now
    local function status(percent)
        ask(self.whisper, { v = Resync.PROTOCOL, t = Resync.TYPE_STATUS, p = percent }, sender,
            { priority = Resync.PRIORITY_STATUS })
    end
    status(0)
    local suffix = string.match(selfKey, "%-[^%-]+$") or ""
    local packed = Resync.Pack(self:facts(partition):ResyncSnapshot(), suffix)
    local step, finished = 0, false
    local function progress(sent, total)
        if type(sent) ~= "number" or type(total) ~= "number" or total <= 0 or finished then
            return
        end
        if sent >= total then
            finished = true
            pcall(self.print, "Finished sending your roster data to " .. sender .. ".")
            return
        end
        local percent = math.floor(sent * 100 / total)
        if math.floor(percent / Resync.STATUS_STEP) > step then
            step = math.floor(percent / Resync.STATUS_STEP)
            status(percent)
        end
    end
    if ask(self.whisper, { v = Resync.PROTOCOL, t = Resync.TYPE_DATA, s = packed }, sender,
        { priority = Resync.PRIORITY_DATA, onProgress = progress }) ~= true
    then
        return false
    end
    pcall(self.print, "Sending your roster data to " .. sender .. ", who asked to resync from you. Please stay "
        .. "online until it's done (a minute or two); you'll see a line here when it is.")
    return true
end

-- The pending answer when `sender` is the officer it's from, or nil.
function Session:pendingFrom(sender)
    local partition, normalizer = ask(self.context)
    local pending = self.pending
    if pending == nil or partition == nil or normalizer == nil then
        return nil
    end
    if self:senderKey(sender, partition, normalizer) ~= pending.key then
        return nil
    end
    return pending
end

-- Seconds as a rough duration for the user.
local function roughly(seconds)
    if seconds < 60 then
        return "under a minute"
    end
    local minutes = math.ceil(seconds / 60)
    return "about " .. minutes .. (minutes == 1 and " minute" or " minutes")
end

-- The officer's "resync-status": shows how far along the roster is, and
-- keeps this add-on waiting. Returns true when it was the one awaited.
function Session:OnStatus(message, sender)
    local pending = self:pendingFrom(sender)
    local now = ask(self.now)
    if type(message) ~= "table" or message.v ~= Resync.PROTOCOL or pending == nil or type(now) ~= "number"
        or type(message.p) ~= "number"
    then
        return false
    end
    pending.deadline = now + Resync.STALL_SECONDS
    local percent = math.max(0, math.min(99, math.floor(message.p)))
    if not pending.heard then
        pending.heard = true
        pending.startedAt = now
        pcall(self.print, pending.name .. " is sending their roster data. This takes a minute or two; you'll see "
            .. "its progress here.")
    end
    if percent > pending.percent then
        pending.percent = percent
        local left = (now - pending.startedAt) * (100 - percent) / percent
        pcall(self.print, "Receiving roster data from " .. pending.name .. ": " .. percent .. "%, " .. roughly(left)
            .. " left.")
    end
    return true
end

-- The officer's "resync-data": applied over this client's roster when it's
-- the answer this add-on is waiting for. Returns how many players changed,
-- or nil when it wasn't applied.
function Session:OnData(message, sender)
    local pending = self:pendingFrom(sender)
    if type(message) ~= "table" or message.v ~= Resync.PROTOCOL or pending == nil then
        return nil
    end
    local partition = ask(self.context)
    self.pending = nil
    if ask(self.isOfficer, pending.key) ~= true then
        pcall(self.print, sender .. " is no longer an officer, so their roster data wasn't applied.")
        return nil
    end
    local own = {}
    partition:EachCharacter(function(characterKey)
        if ask(self.isOwn, characterKey) == true then
            own[characterKey] = true
        end
    end)
    local facts = self:facts(partition)
    local snapshot = Resync.Unpack(message.s)
    local ok, changed = pcall(facts.Overwrite, facts, snapshot, pending.key, own)
    if snapshot == nil or not ok or changed == nil then
        pcall(self.print, "Roster data from " .. sender .. " couldn't be read; nothing changed.")
        return nil
    end
    pcall(self.onApplied, changed)
    local players = changed == 1 and "1 player" or (changed .. " players")
    pcall(self.print, "Resynced from " .. sender .. ": " .. players .. " changed to match their roster.")
    return changed
end

-- Hands a received resync whisper to its handler. False for any other.
function Session:OnMessage(message, sender)
    local handler = type(message) == "table" and Resync.TYPES[message.t] or nil
    if handler == nil then
        return false
    end
    return self[handler](self, message, sender)
end
