local _, addon = ...

-- One party's Guild LFG Board listing, as its leader sees it: what it's
-- for, the note, and what the guild is told. For now a listing is a solo
-- player's group of one, started with Start a group; it expires after
-- SOLO_SECONDS with nobody joining. Pure: members and times are handed in.
--
-- A purpose is one of:
--   { kind = "dungeon", dungeon = { id, name, minLevel, maxLevel } }
--   { kind = "questing", zone = the zone's name }
--   { kind = "raid" }
--   { kind = "other", text = what it's for }
local Protocol = addon.LfgProtocol

local LfgListing = {
    SOLO_SECONDS = 30 * 60,
    NOTE_LETTERS = Protocol.TEXT_LETTERS,
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
        return { kind = "questing", zone = purpose.zone }
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

-- Lists the player as a group of one for `purpose`, with `note`, at `now`.
-- True, or false and why it can't be listed.
function Listing:Start(purpose, note, now)
    local cleaned, reason = LfgListing.CleanPurpose(purpose)
    if cleaned == nil then
        return false, reason
    end
    self.active = true
    self.purpose = cleaned
    self.note = cleanNote(note)
    self.startedAt = now
    self.joined = false
    return true
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
    return true
end

-- Takes the listing off the board (Not looking, or it expired).
function Listing:End()
    self.active = false
    self.purpose = nil
    self.note = nil
    self.startedAt = nil
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

-- A dungeon party's open roles, given its `members`' roles.
local function openRoles(members)
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
-- given the party's `members` (each { name, classToken?, level?, role? },
-- the leader first); nil when it isn't listed.
function Listing:Announcement(members)
    if not self.active then
        return nil
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
        aj = true,
    }
    if purpose.kind == "dungeon" then
        fields.lo = purpose.dungeon.minLevel
        fields.hi = purpose.dungeon.maxLevel
        fields.r = openRoles(members)
    end
    return fields
end
