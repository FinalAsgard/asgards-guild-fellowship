local _, addon = ...

-- One party's Guild LFG Board listing, as its leader sees it: what it's
-- for, the note, and what the guild is told. For now a listing is a solo
-- player's group of one, started with Start a group; it expires after
-- SOLO_SECONDS with nobody joining. Pure: members and times are handed in.
--
-- A purpose is one of:
--   { kind = "dungeon", dungeon = { id, name, minLevel, maxLevel } }
--   { kind = "questing", zone = the zone's name, minLevel?, maxLevel? (its
--     ZoneLevels range) }
--   { kind = "raid" }
--   { kind = "other", text = what it's for }
local Protocol = addon.LfgProtocol

local LfgListing = {
    SOLO_SECONDS = 30 * 60,
    NOTE_LETTERS = Protocol.TEXT_LETTERS,
    -- Ask in guild's line: one guild chat message, and what goes before the
    -- listing's note in it.
    CHAT_BYTES = 255,
    NOTE_PREFIX = " Note: ",
    PURPOSE_LETTERS = Protocol.TEXT_LETTERS,
    PARTY_SIZE = 5,
    RAID_SIZE = 40,
    -- A dungeon party's roles: 1 tank, 1 healer, 3 DPS.
    DUNGEON_ROLES = { { role = "tank", count = 1 }, { role = "healer", count = 1 }, { role = "dps", count = 3 } },
    KIND_LABELS = { dungeon = "Dungeon", questing = "Questing", raid = "Raid", other = "Other" },
}
addon.LfgListing = LfgListing

local Listing = {}
Listing.__index = Listing

function LfgListing.Create()
    return setmetatable({ active = false }, Listing)
end

local function trim(text)
    return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

-- `text` cut to at most `letters` characters, never inside a UTF-8
-- character.
function LfgListing.Truncate(text, letters)
    text = text or ""
    if Protocol.Length(text) <= letters then
        return text
    end
    local count, position = 0, 1
    while position <= #text do
        local byte = string.byte(text, position)
        if byte < 128 or byte >= 192 then
            count = count + 1
            if count > letters then
                return string.sub(text, 1, position - 1)
            end
        end
        position = position + 1
    end
    return text
end

-- The note as it's kept: trimmed, at most NOTE_LETTERS characters, nil
-- when empty.
local function cleanNote(note)
    note = trim(LfgListing.Truncate(trim(note), LfgListing.NOTE_LETTERS))
    return note ~= "" and note or nil
end

-- A purpose as it's kept, or nil and why it can't be.
function LfgListing.CleanPurpose(purpose)
    if type(purpose) ~= "table" then
        return nil, "choose what it's for"
    end
    if purpose.kind == "dungeon" then
        local dungeon = purpose.dungeon
        if type(dungeon) ~= "table" or type(dungeon.name) ~= "string" or dungeon.name == ""
            or type(dungeon.minLevel) ~= "number" or type(dungeon.maxLevel) ~= "number"
        then
            return nil, "choose a dungeon"
        end
        return { kind = "dungeon", dungeon = {
            id = dungeon.id, name = dungeon.name, minLevel = dungeon.minLevel, maxLevel = dungeon.maxLevel,
        } }
    elseif purpose.kind == "questing" then
        if type(purpose.zone) ~= "string" or purpose.zone == "" then
            return nil, "your zone isn't known yet"
        end
        local cleaned = { kind = "questing", zone = purpose.zone }
        if type(purpose.minLevel) == "number" and type(purpose.maxLevel) == "number"
            and purpose.minLevel <= purpose.maxLevel
        then
            cleaned.minLevel = purpose.minLevel
            cleaned.maxLevel = purpose.maxLevel
        end
        return cleaned
    elseif purpose.kind == "raid" then
        return { kind = "raid" }
    elseif purpose.kind == "other" then
        local text = trim(LfgListing.Truncate(trim(purpose.text), LfgListing.PURPOSE_LETTERS))
        if text == "" then
            return nil, "say what it's for"
        end
        return { kind = "other", text = text }
    end
    return nil, "choose what it's for"
end

-- How a listing's purpose reads: the dungeon, "Questing in <zone>", "Raid",
-- or the free text. `kind` and `text` as a listing message carries them.
function LfgListing.Label(kind, text)
    if kind == "questing" then
        return "Questing in " .. tostring(text)
    elseif kind == "raid" then
        return text or "Raid"
    end
    return text
end

-- The kind's name: Dungeon, Questing, Raid or Other.
function LfgListing.KindLabel(kind)
    return LfgListing.KIND_LABELS[kind] or ""
end

-- A purpose's text as a listing message carries it.
local function purposeText(purpose)
    if purpose.kind == "dungeon" then
        return purpose.dungeon.name
    elseif purpose.kind == "questing" then
        return purpose.zone
    elseif purpose.kind == "other" then
        return purpose.text
    end
    return nil
end

-- Lists the player for `purpose`, with `note`, at `now`: as a group of one,
-- or for their party when `party` is true (it then never runs out the solo
-- way). True, or false and why it can't be listed.
-- `guessed` marks a purpose the add-on guessed rather than the leader set.
function Listing:Start(purpose, note, now, party, guessed)
    local cleaned, reason = LfgListing.CleanPurpose(purpose)
    if cleaned == nil then
        return false, reason
    end
    self.active = true
    self.purpose = cleaned
    self.note = cleanNote(note)
    self.startedAt = now
    self.joined = party == true
    self.guessed = guessed == true
    self.held = nil
    self.openRole = nil
    return true
end

-- Whether the purpose is the add-on's guess, not the leader's choice.
function Listing:Guessed()
    return self.active and self.guessed == true
end

-- A best guess at a party's purpose: the dungeon it's in (`dungeon`, {
-- name, minLevel, maxLevel }, or nil), otherwise questing in `zone` (its
-- name) within `levels` ({ minLevel, maxLevel } or nil). Nil when neither
-- is known.
function LfgListing.Guess(dungeon, zone, levels)
    if dungeon ~= nil then
        return { kind = "dungeon", dungeon = dungeon }
    end
    if type(zone) ~= "string" or zone == "" then
        return nil
    end
    return { kind = "questing", zone = zone, minLevel = levels and levels.minLevel or nil,
        maxLevel = levels and levels.maxLevel or nil }
end

-- The party entered dungeon `dungeon`: a guessed purpose becomes it; one the
-- leader set is left alone. True when the purpose changed.
function Listing:EnteredDungeon(dungeon)
    if not self:Guessed() or dungeon == nil then
        return false
    end
    local current = self.purpose
    if current.kind == "dungeon" and current.dungeon.name == dungeon.name then
        return false
    end
    local cleaned = LfgListing.CleanPurpose({ kind = "dungeon", dungeon = dungeon })
    if cleaned == nil then
        return false
    end
    self.purpose = cleaned
    return true
end

-- Someone left: the listing is announced with `members` (the party as it
-- was) until the open slot is posted or the party fills up again.
function Listing:Hold(members)
    if self.active and self.held == nil then
        self.held = members
    end
end

-- Whether the listing is held as the party was.
function Listing:Held()
    return self.held ~= nil
end

-- Posts the open slot: the listing is announced as the party is now, and a
-- dungeon's one open slot as `role` (the role of whoever left, where it's
-- known), until the party changes size.
function Listing:Post(role)
    self.held = nil
    self.openRole = role
end

-- `members` (each { key, classToken, assignedRole?, role?, ... }) with each
-- one's dungeon role: the game's (set in the game's party menu), else the
-- one they have (the player's own preference), else the first
-- `rolesFor(classToken)` gives.
function LfgListing.FillRoles(members, rolesFor)
    local filled = {}
    local index
    for index = 1, #members do
        local member = members[index]
        local copy = {}
        local name, value
        for name, value in pairs(member) do
            copy[name] = value
        end
        local playable = rolesFor(member.classToken) or {}
        copy.role = member.assignedRole or member.role or playable[1]
        filled[index] = copy
    end
    return filled
end

-- Changes a live listing's purpose and note. True, or false and why not.
function Listing:Update(purpose, note)
    if not self.active then
        return false, "you're not listed"
    end
    local cleaned, reason = LfgListing.CleanPurpose(purpose)
    if cleaned == nil then
        return false, reason
    end
    self.purpose = cleaned
    self.note = cleanNote(note)
    -- Set by hand now.
    self.guessed = false
    return true
end

-- Takes the listing off the board (Not looking, or it expired).
function Listing:End()
    self.active = false
    self.purpose = nil
    self.note = nil
    self.startedAt = nil
    self.held = nil
    self.openRole = nil
end

function Listing:IsActive()
    return self.active == true
end

function Listing:Purpose()
    return self.purpose
end

function Listing:Note()
    return self.note
end

-- Whether the listing has run out at `now`: a group of one nobody joined
-- for SOLO_SECONDS. Once the group is bigger than one (`size`), it never
-- runs out this way.
function Listing:Expired(now, size)
    if not self.active then
        return false
    end
    if type(size) == "number" and size > 1 then
        self.joined = true
    end
    return not self.joined and type(now) == "number" and type(self.startedAt) == "number"
        and now - self.startedAt >= LfgListing.SOLO_SECONDS
end

-- A dungeon party's open roles, given its `members`' roles; none once it's
-- full.
local function openRoles(members)
    if #members >= LfgListing.PARTY_SIZE then
        return {}
    end
    local taken = {}
    local index
    for index = 1, #members do
        local role = members[index].role
        if role ~= nil then
            taken[role] = (taken[role] or 0) + 1
        end
    end
    local open = {}
    for index = 1, #LfgListing.DUNGEON_ROLES do
        local slot = LfgListing.DUNGEON_ROLES[index]
        if (taken[slot.role] or 0) < slot.count then
            table.insert(open, slot.role)
        end
    end
    return open
end

-- What the guild is told of the listing, as LfgProtocol.Listing's fields,
-- given the party's `members` (each { name, classToken?, level?, role?,
-- isPlayer? }, the leader first); nil when it isn't listed. When the
-- leader isn't the player (isPlayer false), the player is its contact.
-- Ask to join is accepted unless `accepts` is false (the LFG button is
-- hidden) or the player is the contact (they can't invite). While held,
-- it's the party as it was, until the party is that big again.
function Listing:Announcement(members, accepts)
    if not self.active then
        return nil
    end
    if self.held ~= nil then
        if #members >= #self.held then
            self.held = nil
        else
            members = self.held
        end
    end
    if self.held == nil and #members ~= LfgListing.PARTY_SIZE - 1 then
        self.openRole = nil
    end
    local purpose = self.purpose
    local listed = {}
    local index
    for index = 1, #members do
        local member = members[index]
        listed[index] = { n = member.name, c = member.classToken, l = member.level, r = member.role }
    end
    local fields = {
        k = purpose.kind,
        p = purposeText(purpose),
        s = #members,
        x = purpose.kind == "raid" and LfgListing.RAID_SIZE or LfgListing.PARTY_SIZE,
        no = self.note,
        mb = listed,
        ct = members[1] ~= nil and members[1].isPlayer == false or nil,
    }
    fields.aj = accepts ~= false and not fields.ct
    if purpose.kind == "dungeon" then
        fields.lo = purpose.dungeon.minLevel
        fields.hi = purpose.dungeon.maxLevel
        fields.r = openRoles(members)
        if self.openRole ~= nil then
            fields.r = { self.openRole }
        end
    elseif purpose.kind == "questing" then
        fields.lo = purpose.minLevel
        fields.hi = purpose.maxLevel
    end
    return fields
end

-- The line Ask in guild types into guild chat for guildmates without the
-- add-on, from an Announcement's `fields`: the open roles for a dungeon
-- ("LF healer and 2 DPS for Stratholme (58–60), whisper me!"), else how
-- many more players, then the listing's note when it has one ("... whisper
-- me! Note: bring a key"). Nil when nobody's needed. A note too long for
-- one chat message is shortened to fit.
function LfgListing.GuildLine(fields)
    if type(fields) ~= "table" then
        return nil
    end
    local label = LfgListing.Label(fields.k, fields.p)
    if fields.lo ~= nil and fields.hi ~= nil then
        label = label .. " (" .. fields.lo .. "\226\128\147" .. fields.hi .. ")"
    end
    local wanted = {}
    if fields.k == "dungeon" then
        local taken = {}
        local index
        for index = 1, #(fields.mb or {}) do
            local role = fields.mb[index].r
            if role ~= nil then
                taken[role] = (taken[role] or 0) + 1
            end
        end
        local open = {}
        for index = 1, #(fields.r or {}) do
            open[fields.r[index]] = true
        end
        for index = 1, #LfgListing.DUNGEON_ROLES do
            local slot = LfgListing.DUNGEON_ROLES[index]
            if open[slot.role] then
                local count = math.max(slot.count - (taken[slot.role] or 0), 1)
                local name = slot.role == "dps" and "DPS" or slot.role
                table.insert(wanted, count > 1 and (count .. " " .. name) or name)
            end
        end
    else
        local more = (fields.x or 0) - (fields.s or 0)
        if more > 0 then
            wanted[1] = more .. " more"
        end
    end
    if wanted[1] == nil then
        return nil
    end
    local roles = wanted[1]
    local index
    for index = 2, #wanted do
        roles = roles .. (index == #wanted and " and " or ", ") .. wanted[index]
    end
    local line = "LF " .. roles .. " for " .. label .. ", whisper me!"
    local note = type(fields.no) == "string" and string.match(fields.no, "^%s*(.-)%s*$") or ""
    if note == "" then
        return line
    end
    local room = LfgListing.CHAT_BYTES - #line - #LfgListing.NOTE_PREFIX
    local letters = Protocol.Length(note)
    while #note > room and letters > 0 do
        letters = letters - 1
        note = LfgListing.Truncate(note, letters)
    end
    if note == "" then
        return line
    end
    return line .. LfgListing.NOTE_PREFIX .. note
end
