local test = require("tests.test_helper")
local FakeFrames = require("tests.fake_frames")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
        "Core/RosterViewModel.lua",
        "Core/GuildGreet.lua",
        "Core/GuildMailAudience.lua",
        "Core/GuildMailSender.lua",
        "Core/GuildMail.lua"
    )
end

-- Ranks: 0 Guild Master, 1 Officer, 2 Member, 3 Initiate.
--   Tool Box (Officer, the sender) with alt Hammer Smith (Initiate)
--   Ann Bell (Member) with alt Cog Wheel (Initiate)
--   Zed Stone (Initiate), a lone character: its own main
--   Bo Reed (Initiate), with a declared main Gus Reed (Member)
--   Ivy Gone (Initiate), departed
local function seedGuild(partition)
    partition:RecordCharacter("tool box-camelot", { name = "Tool Box", rankIndex = 1 })
    partition:RecordCharacter("hammer smith-camelot", { name = "Hammer Smith", rankIndex = 3 })
    partition:JoinPlayerOf("hammer smith-camelot", "tool box-camelot", "note")
    partition:RecordCharacter("ann bell-camelot", { name = "Ann Bell", rankIndex = 2 })
    partition:RecordCharacter("cog wheel-camelot", { name = "Cog Wheel", rankIndex = 3 })
    partition:JoinPlayerOf("cog wheel-camelot", "ann bell-camelot", "note")
    partition:RecordCharacter("zed stone-camelot", { name = "Zed Stone", rankIndex = 3 })
    partition:RecordCharacter("gus reed-camelot", { name = "Gus Reed", rankIndex = 2 })
    partition:RecordCharacter("bo reed-camelot", { name = "Bo Reed", rankIndex = 3 })
    partition:JoinPlayerOf("bo reed-camelot", "gus reed-camelot", "note")
    partition:RecordCharacter("ivy gone-camelot", { name = "Ivy Gone", rankIndex = 3 })
    partition:MarkDeparted("ivy gone-camelot", 100)
end

local function setup()
    local addon = load()
    local store = addon.FellowshipStore.Create({ schemaVersion = 1, guilds = {} })
    local partition = store:Partition({ name = "Knights", realm = "Camelot" })
    seedGuild(partition)
    return addon, partition
end

local function names(recipients)
    local result = {}
    local index
    for index = 1, #recipients do
        result[index] = recipients[index].name
    end
    return table.concat(result, ",")
end

local function recipientsFor(ranks, selfKey, mode, live)
    local addon, partition = setup()
    return addon.GuildMailAudience.Recipients(partition, {
        ranks = ranks, selfKey = selfKey, mode = mode, live = live,
    })
end

-- Live roster facts: Cog Wheel is online; Ann Bell was on 3 days ago; Gus
-- and Bo Reed both 2 days ago; Zed Stone isn't in the live roster.
local LIVE = {
    ["ann bell-camelot"] = { online = false, lastOnline = { years = 0, months = 0, days = 3, hours = 0 } },
    ["cog wheel-camelot"] = { online = true },
    ["gus reed-camelot"] = { online = false, lastOnline = { years = 0, months = 0, days = 2, hours = 0 } },
    ["bo reed-camelot"] = { online = false, lastOnline = { years = 0, months = 0, days = 2, hours = 0 } },
}

-- Audience ------------------------------------------------------------------

test.test("guild mail audience: one mail per player, to the main, in any mix of ranks", function()
    test.assertEqual("Ann Bell,Gus Reed", names(recipientsFor({ [2] = true })))
    test.assertEqual("Ann Bell,Gus Reed,Zed Stone", names(recipientsFor({ [2] = true, [3] = true })))
end)

test.test("guild mail audience: a lone character is its own main", function()
    local recipients = recipientsFor({ [3] = true })

    test.assertEqual("Zed Stone", names(recipients))
    test.assertEqual("zed stone-camelot", recipients[1].key)
    test.assertEqual(3, recipients[1].rank)
end)

test.test("guild mail audience: a player whose main is outside the ticked ranks gets nothing", function()
    -- Hammer Smith, Cog Wheel and Bo Reed are Initiates, but their mains
    -- aren't.
    local recipients = recipientsFor({ [3] = true })

    test.assertEqual(nil, string.find(names(recipients), "Hammer Smith", 1, true))
    test.assertEqual(nil, string.find(names(recipients), "Cog Wheel", 1, true))
    test.assertEqual(nil, string.find(names(recipients), "Bo Reed", 1, true))
end)

test.test("guild mail audience: the sender's own player is never mailed", function()
    test.assertEqual("Tool Box", names(recipientsFor({ [1] = true })))
    test.assertEqual("", names(recipientsFor({ [1] = true }, "tool box-camelot")))
    -- Sending from an alt skips the main too.
    test.assertEqual("", names(recipientsFor({ [1] = true }, "hammer smith-camelot")))
end)

test.test("guild mail audience: departed characters are never mailed", function()
    test.assertEqual(nil, string.find(names(recipientsFor({ [3] = true })), "Ivy Gone", 1, true))
end)

test.test("guild mail audience: sorted by rank, then name, with no one twice", function()
    local recipients = recipientsFor({ [1] = true, [2] = true, [3] = true })

    test.assertEqual("Tool Box,Ann Bell,Gus Reed,Zed Stone", names(recipients))
    local seen = {}
    local index
    for index = 1, #recipients do
        test.assertEqual(nil, seen[recipients[index].key])
        seen[recipients[index].key] = true
    end
end)

test.test("guild mail audience: most recently online picks one character per player", function()
    local recipients = recipientsFor({ [2] = true, [3] = true }, "tool box-camelot", "recent", LIVE)

    -- Cog Wheel is online, so beats Ann Bell; Bo and Gus Reed tie on 2 days
    -- and Bo comes first by name; Zed Stone is his player's only candidate.
    test.assertEqual("Bo Reed,Cog Wheel,Zed Stone", names(recipients))
    test.assertEqual(0, recipients[2].hoursAway)
    test.assertEqual(48, recipients[1].hoursAway)
end)

test.test("guild mail audience: most recently online only picks from the ticked ranks", function()
    -- Cog Wheel is online but an Initiate; only Ann Bell is a Member.
    local recipients = recipientsFor({ [2] = true }, nil, "recent", LIVE)

    test.assertEqual("Ann Bell,Gus Reed", names(recipients))
end)

test.test("guild mail audience: a character the live roster doesn't know sorts after known ones", function()
    local recipients = recipientsFor({ [2] = true, [3] = true }, nil, "recent", {
        ["ann bell-camelot"] = { online = false, lastOnline = { years = 1, months = 0, days = 0, hours = 0 } },
    })

    test.assertEqual("Ann Bell", recipients[1].name)
    test.assertEqual(nil, string.find(names(recipients), "Cog Wheel", 1, true))
end)

test.test("guild mail audience: every character mails each candidate", function()
    local recipients = recipientsFor({ [2] = true, [3] = true }, "tool box-camelot", "all", LIVE)

    test.assertEqual("Ann Bell,Gus Reed,Bo Reed,Cog Wheel,Zed Stone", names(recipients))
end)

test.test("guild mail audience: each recipient knows its player and when it was last online", function()
    local addon, partition = setup()
    partition:SetAlias(partition:GetCharacter("ann bell-camelot").player, "Annie", "note")

    local recipients = addon.GuildMailAudience.Recipients(partition, {
        ranks = { [3] = true }, mode = "all", live = LIVE,
    })

    local cog
    local index
    for index = 1, #recipients do
        if recipients[index].name == "Cog Wheel" then
            cog = recipients[index]
        end
    end
    test.assertEqual("Annie", cog.playerName)
    test.assertTrue(cog.online)
    test.assertEqual("Zed Stone", recipients[#recipients].playerName)
end)

local function audience(options)
    local addon, partition = setup()
    if options.before then
        options.before(partition)
    end
    options.before = nil
    options.selfKey = options.selfKey or "tool box-camelot"
    return addon.GuildMailAudience.Recipients(partition, options)
end

test.test("guild mail audience: a Discord name on any character skips the whole player", function()
    local recipients = audience({
        ranks = { [2] = true, [3] = true }, mode = "all", skipDiscord = true,
        before = function(partition)
            -- Set on Cog Wheel, an alt: Ann Bell goes too.
            partition:SetProfileText("cog wheel-camelot", "discord", "annie#1234", 10, "cog wheel-camelot")
        end,
    })

    test.assertEqual("Gus Reed,Bo Reed,Zed Stone", names(recipients))
end)

test.test("guild mail audience: a blank Discord name doesn't count as one", function()
    local recipients = audience({
        ranks = { [2] = true }, skipDiscord = true,
        before = function(partition)
            partition:SetProfileText("gus reed-camelot", "discord", "   ", 10, "gus reed-camelot")
            partition:SetProfileText("ann bell-camelot", "discord", "", 10, "ann bell-camelot")
        end,
    })

    test.assertEqual("Ann Bell,Gus Reed", names(recipients))
end)

test.test("guild mail audience: without the box ticked, Discord names don't matter", function()
    local recipients = audience({
        ranks = { [2] = true },
        before = function(partition)
            partition:SetProfileText("ann bell-camelot", "discord", "annie#1234", 10, "ann bell-camelot")
        end,
    })

    test.assertEqual("Ann Bell,Gus Reed", names(recipients))
end)

local EDGES = {
    ["zed stone-camelot"] = { online = false, lastOnline = { years = 0, months = 0, days = 30, hours = 0 } },
    ["gus reed-camelot"] = { online = false, lastOnline = { years = 0, months = 0, days = 30, hours = 1 } },
    ["bo reed-camelot"] = { online = false, lastOnline = { years = 0, months = 1, days = 0, hours = 0 } },
    ["cog wheel-camelot"] = { online = true },
}

test.test("guild mail audience: only characters online in the last 30 days, at the edges", function()
    -- Exactly 30 days and "1 month" are in; 30 days and an hour is out;
    -- Ann Bell isn't in the live roster, so she's out too.
    local recipients = audience({ ranks = { [2] = true, [3] = true }, mode = "all", live = EDGES, activeDays = 30 })

    test.assertEqual("Bo Reed,Cog Wheel,Zed Stone", names(recipients))
end)

test.test("guild mail audience: the 30-day filter applies before the mode picks", function()
    -- Gus Reed's main is out, so Mains only mails nobody of his player;
    -- most recently online then picks Bo Reed.
    test.assertEqual("Zed Stone", names(audience({
        ranks = { [2] = true, [3] = true }, mode = "mains", live = EDGES, activeDays = 30,
    })))
    test.assertEqual("Bo Reed,Cog Wheel,Zed Stone", names(audience({
        ranks = { [2] = true, [3] = true }, mode = "recent", live = EDGES, activeDays = 30,
    })))
end)

test.test("guild mail audience: no ranks ticked means no one", function()
    test.assertEqual("", names(recipientsFor({})))
end)

-- Sender --------------------------------------------------------------------

local function newSender(takes)
    local addon = load()
    local world = { sent = {}, changes = 0 }
    world.sender = addon.GuildMailSender.Create({
        send = function(mail)
            table.insert(world.sent, mail.to)
            if takes ~= nil then
                return takes(mail)
            end
            return true
        end,
        onChange = function()
            world.changes = world.changes + 1
        end,
    })
    return addon, world
end

local MAILS = {
    { to = "Ann Bell", subject = "Hi", body = "Launch night" },
    { to = "Gus Reed", subject = "Hi", body = "Launch night" },
    { to = "Zed Stone", subject = "Hi", body = "Launch night" },
}

test.test("guild mail sender: only one mail is in flight; the next waits for the game", function()
    local _, world = newSender()

    test.assertTrue(world.sender:Start(MAILS))
    test.assertEqual("Ann Bell", table.concat(world.sent, ","))
    test.assertTrue(world.sender:IsSending())

    test.assertTrue(world.sender:OnSent())
    test.assertEqual("Ann Bell,Gus Reed", table.concat(world.sent, ","))
end)

test.test("guild mail sender: it carries on after a success and after a failure", function()
    local addon, world = newSender()
    world.sender:Start(MAILS)

    world.sender:OnSent()
    world.sender:OnFailed("Mailbox full")
    test.assertEqual("Ann Bell,Gus Reed,Zed Stone", table.concat(world.sent, ","))
    world.sender:OnSent()

    test.assertFalse(world.sender:IsSending())
    test.assertEqual(addon.GuildMailSender.SENT, (world.sender:Status(1)))
    local status, reason = world.sender:Status(2)
    test.assertEqual(addon.GuildMailSender.FAILED, status)
    test.assertEqual("Mailbox full", reason)
end)

test.test("guild mail sender: progress counts sent and failed mails", function()
    local addon, world = newSender()
    world.sender:Start(MAILS)

    local progress = world.sender:Progress()
    test.assertEqual(0, progress.sent)
    test.assertEqual(3, progress.total)
    test.assertEqual(addon.GuildMailSender.SENDING, progress.state)

    world.sender:OnSent()
    world.sender:OnFailed(nil)
    world.sender:OnSent()
    progress = world.sender:Progress()
    test.assertEqual(2, progress.sent)
    test.assertEqual(1, progress.failed)
    test.assertEqual(addon.GuildMailSender.DONE, progress.state)
    test.assertTrue(world.changes >= 4)
end)

test.test("guild mail sender: answers with nothing in flight are ignored", function()
    local _, world = newSender()

    test.assertFalse(world.sender:OnSent())
    world.sender:Start({ MAILS[1] })
    world.sender:OnSent()
    test.assertFalse(world.sender:OnSent())
    test.assertEqual(1, world.sender:Progress().sent)
end)

test.test("guild mail sender: a mail the client won't take fails at once and the next is tried", function()
    local addon, world = newSender(function(mail)
        return mail.to ~= "Ann Bell"
    end)

    world.sender:Start(MAILS)

    test.assertEqual("Ann Bell,Gus Reed", table.concat(world.sent, ","))
    local status, reason = world.sender:Status(1)
    test.assertEqual(addon.GuildMailSender.FAILED, status)
    test.assertEqual(addon.GuildMailSender.REFUSED, reason)
end)

test.test("guild mail sender: a second start while sending is refused, and nothing to send is refused", function()
    local _, world = newSender()

    test.assertFalse(world.sender:Start({}))
    world.sender:Start(MAILS)
    test.assertFalse(world.sender:Start(MAILS))
    test.assertEqual(1, #world.sent)
end)

-- A sender with a timer the spec runs by hand: `world.timers` holds the
-- callbacks set, with their delays.
local function newTimedSender()
    local addon = load()
    local world = { sent = {}, timers = {} }
    world.sender = addon.GuildMailSender.Create({
        send = function(mail)
            table.insert(world.sent, mail.to)
            return true
        end,
        after = function(seconds, callback)
            table.insert(world.timers, { seconds = seconds, run = callback })
            return true
        end,
    })
    -- Runs every timer set so far with this delay.
    function world.fire(seconds)
        local due = {}
        local index
        for index = 1, #world.timers do
            if world.timers[index].seconds == seconds then
                table.insert(due, world.timers[index].run)
            end
        end
        for index = 1, #due do
            due[index]()
        end
    end
    return addon, world
end

test.test("guild mail sender: the next mail waits a moment after the game's answer", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)

    world.sender:OnSent()
    test.assertEqual("Ann Bell", table.concat(world.sent, ","))

    world.fire(addon.GuildMailSender.GAP_SECONDS)
    test.assertEqual("Ann Bell,Gus Reed", table.concat(world.sent, ","))
end)

test.test("guild mail sender: no answer in time pauses, and Send next sends it again", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)

    world.fire(addon.GuildMailSender.ANSWER_SECONDS)
    test.assertTrue(world.sender:IsPaused())
    test.assertTrue(world.sender:IsSending())
    test.assertTrue(world.sender:IsManual())

    test.assertTrue(world.sender:Resume())
    test.assertEqual("Ann Bell,Gus Reed,Gus Reed", table.concat(world.sent, ","))
    test.assertFalse(world.sender:IsPaused())
end)

test.test("guild mail sender: after a pause, every mail waits for a click", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.fire(addon.GuildMailSender.ANSWER_SECONDS)
    world.sender:Resume()

    world.sender:OnSent()
    test.assertTrue(world.sender:IsPaused())
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    test.assertEqual("Ann Bell,Ann Bell", table.concat(world.sent, ","))

    world.sender:Resume()
    test.assertEqual("Ann Bell,Ann Bell,Gus Reed", table.concat(world.sent, ","))
end)

test.test("guild mail sender: a blocked send pauses at once and never counts as sent", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)

    test.assertTrue(world.sender:OnBlocked())
    test.assertTrue(world.sender:IsPaused())
    -- The player's own mail answered meanwhile isn't this one.
    test.assertFalse(world.sender:OnSent())
    test.assertEqual(addon.GuildMailSender.PENDING, (world.sender:Status(1)))
end)

test.test("guild mail sender: a late answer to a paused mail still counts", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.fire(addon.GuildMailSender.ANSWER_SECONDS)

    test.assertTrue(world.sender:OnSent())
    test.assertEqual(addon.GuildMailSender.SENT, (world.sender:Status(1)))
    -- The next one waits for a click; a stray answer doesn't count for it.
    test.assertTrue(world.sender:IsPaused())
    test.assertFalse(world.sender:OnSent())
    test.assertEqual(addon.GuildMailSender.PENDING, (world.sender:Status(2)))
end)

test.test("guild mail sender: an error soon after a send fails that mail and moves on", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)

    test.assertTrue(world.sender:OnError("Please enter a full character name."))
    local status, reason = world.sender:Status(1)
    test.assertEqual(addon.GuildMailSender.FAILED, status)
    test.assertEqual("Please enter a full character name.", reason)
    test.assertFalse(world.sender:IsManual())
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    test.assertEqual("Ann Bell,Gus Reed", table.concat(world.sent, ","))
end)

test.test("guild mail sender: the error after a failure is its reason", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)

    world.sender:OnFailed(nil)
    test.assertTrue(world.sender:OnError("Cannot find mail recipient."))
    local _, reason = world.sender:Status(1)
    test.assertEqual("Cannot find mail recipient.", reason)
    -- The next mail isn't touched by it, and a second error is ignored.
    test.assertEqual(addon.GuildMailSender.PENDING, (world.sender:Status(2)))
    test.assertFalse(world.sender:OnError("Something else"))
end)

test.test("guild mail sender: an error long after a send leaves the mail waiting", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.fire(addon.GuildMailSender.ERROR_SECONDS)

    test.assertFalse(world.sender:OnError("Not enough mana"))
    test.assertEqual(addon.GuildMailSender.PENDING, (world.sender:Status(1)))
    test.assertTrue(world.sender:OnSent())
end)

test.test("guild mail sender: a stale timer does nothing", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    world.sender:OnSent()

    -- The first two mails' answer timers are stale now.
    local before = #world.sent
    world.fire(addon.GuildMailSender.ANSWER_SECONDS)
    test.assertFalse(world.sender:IsPaused())
    test.assertEqual(before, #world.sent)
end)

-- Guild Mail ----------------------------------------------------------------

local RANK_NAMES = { "Guild Master", "Officer", "Member", "Initiate" }

local function newMail(overrides)
    overrides = overrides or {}
    local addon, partition = setup()
    local world = { sent = {}, renders = 0, officer = overrides.officer ~= false, partition = partition }
    world.view = {
        shown = false,
        Show = function(self, fromMailbox)
            self.shown = true
            self.fromMailbox = fromMailbox
        end,
        IsShown = function(self)
            return self.shown
        end,
        Render = function(self, model)
            world.renders = world.renders + 1
            self.model = model
        end,
    }
    world.mail = addon.GuildMail.Create({
        context = function()
            if overrides.noGuild then
                return nil
            end
            return partition
        end,
        selfKey = function()
            return "tool box-camelot"
        end,
        isOfficer = function()
            return world.officer
        end,
        rankNames = function()
            return overrides.rankNames or RANK_NAMES
        end,
        live = function()
            return LIVE
        end,
        send = function(to, subject, body)
            table.insert(world.sent, { to = to, subject = subject, body = body })
            return true
        end,
        price = function()
            return world.price
        end,
        money = function()
            return world.money
        end,
        formatMoney = overrides.formatMoney,
        view = world.view,
    })
    return addon, world
end

local function readyToSend(world)
    world.mail:SetRank(2, true)
    world.mail:SetSubject("Launch night")
    world.mail:SetBody("Join us on Discord!")
    world.mail:OnMailboxOpened()
end

test.test("guild mail: only officers can open it", function()
    local addon, world = newMail({ officer = false })

    local opened, reason = world.mail:Open(false)

    test.assertFalse(opened)
    test.assertEqual(addon.GuildMail.OFFICERS_ONLY, reason)
    test.assertFalse(world.view.shown)
    test.assertFalse(world.mail:ShowsMailboxButton())
end)

test.test("guild mail: an officer opens it beside the mailbox or anywhere", function()
    local _, world = newMail()

    test.assertTrue(world.mail:ShowsMailboxButton())
    test.assertTrue(world.mail:Open(true))
    test.assertTrue(world.view.shown)
    test.assertTrue(world.view.fromMailbox)
    test.assertTrue(world.renders > 0)
end)

test.test("guild mail: outside a guild it doesn't open", function()
    local addon, world = newMail({ noGuild = true })

    local opened, reason = world.mail:Open(false)

    test.assertFalse(opened)
    test.assertEqual(addon.GuildMail.NO_GUILD, reason)
end)

test.test("guild mail: the window lists every rank, highest first, with its ticks", function()
    local _, world = newMail()
    world.mail:Open(false)
    world.mail:SetRank(2, true)

    local ranks = world.view.model.ranks
    test.assertEqual(4, #ranks)
    test.assertEqual(0, ranks[1].index)
    test.assertEqual("Guild Master", ranks[1].name)
    test.assertFalse(ranks[1].checked)
    test.assertEqual("Member", ranks[3].name)
    test.assertTrue(ranks[3].checked)
end)

test.test("guild mail: without rank names, the ranks in the roster are listed", function()
    local _, world = newMail({ rankNames = {} })

    local ranks = world.mail:Model().ranks

    test.assertEqual(3, #ranks)
    test.assertEqual(1, ranks[1].index)
    test.assertEqual("Rank 2", ranks[1].name)
end)

test.test("guild mail: the recipient list follows the ticked ranks", function()
    local _, world = newMail()
    world.mail:Open(false)

    world.mail:SetRank(2, true)
    local model = world.view.model
    test.assertEqual("2 mails", model.countText)
    test.assertEqual("Ann Bell", model.recipients[1].name)
    test.assertEqual("Member", model.recipients[1].rankName)

    world.mail:SetRank(3, true)
    test.assertEqual("3 mails", world.view.model.countText)
    world.mail:SetRank(2, false)
    test.assertEqual("1 mail", world.view.model.countText)
end)

test.test("guild mail: Send to starts on mains only and can be changed", function()
    local _, world = newMail()
    world.mail:Open(false)
    world.mail:SetRank(2, true)
    world.mail:SetRank(3, true)

    local modes = world.view.model.modes
    test.assertEqual("mains", modes[1].id)
    test.assertTrue(modes[1].checked)
    test.assertEqual("3 mails", world.view.model.countText)

    test.assertTrue(world.mail:SetMode("all"))
    test.assertTrue(world.view.model.modes[3].checked)
    -- Tool Box's own alt Hammer Smith is still skipped.
    test.assertEqual("5 mails", world.view.model.countText)

    test.assertTrue(world.mail:SetMode("recent"))
    test.assertEqual("Cog Wheel", world.view.model.recipients[2].name)
    test.assertFalse(world.mail:SetMode("recent"))
    test.assertFalse(world.mail:SetMode("everyone"))
end)

test.test("guild mail: recipient rows show the player and when they were last online", function()
    local _, world = newMail()
    world.mail:SetRank(3, true)
    world.mail:SetMode("all")

    local rows = world.mail:Model().recipients
    test.assertEqual("Cog Wheel", rows[2].name)
    test.assertEqual("Ann Bell", rows[2].playerName)
    test.assertEqual("Online", rows[2].lastSeen)
    test.assertEqual("Bo Reed", rows[1].name)
    test.assertEqual("2 days ago", rows[1].lastSeen)
    test.assertEqual("Zed Stone", rows[3].name)
    test.assertEqual("", rows[3].lastSeen)
end)

test.test("guild mail: the skip boxes start off and change the list", function()
    local _, world = newMail()
    world.partition:SetProfileText("ann bell-camelot", "discord", "annie#1234", 10, "ann bell-camelot")
    world.mail:Open(false)
    world.mail:SetRank(2, true)

    test.assertFalse(world.view.model.skipDiscord)
    test.assertFalse(world.view.model.activeOnly)
    test.assertEqual("2 mails", world.view.model.countText)

    test.assertTrue(world.mail:SetSkipDiscord(true))
    test.assertTrue(world.view.model.skipDiscord)
    test.assertEqual("Gus Reed", world.view.model.recipients[1].name)
    test.assertFalse(world.mail:SetSkipDiscord(true))

    -- In LIVE, Gus Reed was on 2 days ago.
    test.assertTrue(world.mail:SetActiveOnly(true))
    test.assertEqual("1 mail", world.view.model.countText)
    world.mail:SetSkipDiscord(false)
    test.assertEqual("2 mails", world.view.model.countText)
end)

test.test("guild mail: Send to can't change while sending", function()
    local _, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()

    test.assertFalse(world.mail:SetMode("all"))
    test.assertFalse(world.mail:SetSkipDiscord(true))
    test.assertFalse(world.mail:SetActiveOnly(true))
end)

test.test("guild mail: Send waits for ranks, recipients, a subject and an open mailbox", function()
    local addon, world = newMail()

    test.assertEqual(addon.GuildMail.HINT_NO_RANKS, world.mail:Model().hint)
    world.mail:SetRank(0, true)
    test.assertEqual(addon.GuildMail.HINT_NOBODY, world.mail:Model().hint)
    world.mail:SetRank(2, true)
    test.assertEqual(addon.GuildMail.HINT_NO_SUBJECT, world.mail:Model().hint)
    world.mail:SetSubject("   ")
    test.assertEqual(addon.GuildMail.HINT_NO_SUBJECT, world.mail:Model().hint)
    world.mail:SetSubject("Launch night")
    test.assertEqual(addon.GuildMail.HINT_NO_MAILBOX, world.mail:Model().hint)
    test.assertFalse(world.mail:Model().canSend)
    test.assertFalse(world.mail:RequestSend())

    world.mail:OnMailboxOpened()
    test.assertEqual(nil, world.mail:Model().hint)
    test.assertTrue(world.mail:Model().canSend)

    world.mail:OnMailboxClosed()
    test.assertEqual(addon.GuildMail.HINT_NO_MAILBOX, world.mail:Model().hint)
end)

test.test("guild mail: nothing is sent until the officer confirms", function()
    local _, world = newMail()
    readyToSend(world)

    test.assertTrue(world.mail:RequestSend())
    local model = world.mail:Model()
    test.assertTrue(model.confirming)
    test.assertEqual("Send 2 mails for 60c postage?", model.confirmText)
    test.assertEqual(0, #world.sent)

    world.mail:Cancel()
    test.assertFalse(world.mail:Model().confirming)
    test.assertFalse(world.mail:Confirm())
    test.assertEqual(0, #world.sent)
end)

test.test("guild mail: confirmed mails go out one at a time, with progress", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:Open(true)

    world.mail:RequestSend()
    test.assertTrue(world.mail:Confirm())

    test.assertEqual(1, #world.sent)
    test.assertEqual("Ann Bell", world.sent[1].to)
    test.assertEqual("Launch night", world.sent[1].subject)
    test.assertEqual("Join us on Discord!", world.sent[1].body)
    test.assertEqual("Sent 0 of 2 · Postage spent: 0c", world.view.model.progressText)
    test.assertEqual(addon.GuildMail.HINT_SENDING, world.view.model.hint)
    test.assertEqual(addon.GuildMailSender.PENDING, world.view.model.recipients[1].status)

    world.mail:OnSent()
    test.assertEqual(2, #world.sent)
    test.assertEqual("Gus Reed", world.sent[2].to)
    test.assertEqual("Sent 1 of 2 · Postage spent: 30c", world.view.model.progressText)

    world.mail:OnSent()
    test.assertEqual("Sent 2 of 2 · Postage spent: 60c. Done.", world.view.model.progressText)
    test.assertEqual(addon.GuildMailSender.SENT, world.view.model.recipients[2].status)
end)

test.test("guild mail: when the game stalls, Send becomes Send next", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()

    test.assertTrue(world.mail:OnBlocked())
    local model = world.mail:Model()
    test.assertEqual(addon.GuildMail.SEND_NEXT_TEXT, model.sendText)
    test.assertTrue(model.canSend)
    test.assertEqual(addon.GuildMail.HINT_PAUSED, model.hint)

    test.assertTrue(world.mail:RequestSend())
    test.assertEqual(2, #world.sent)
    test.assertEqual("Ann Bell", world.sent[2].to)
    test.assertEqual(addon.GuildMail.SEND_TEXT, world.mail:Model().sendText)
end)

test.test("guild mail: Send next needs the mailbox open", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()
    world.mail:OnBlocked()
    world.mail:OnMailboxClosed()

    test.assertFalse(world.mail:Model().canSend)
    test.assertEqual(addon.GuildMail.HINT_NO_MAILBOX, world.mail:Model().hint)
    test.assertFalse(world.mail:RequestSend())
end)

test.test("guild mail: ranks and text can't change while sending", function()
    local _, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()

    test.assertFalse(world.mail:SetRank(3, true))
    test.assertFalse(world.mail:SetSubject("Changed"))
    world.mail:OnSent()
    world.mail:OnSent()
    test.assertEqual("Launch night", world.sent[2].subject)
end)

test.test("guild mail: a finished send can't go again until something changes", function()
    local _, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()
    world.mail:OnSent()
    world.mail:OnSent()

    test.assertFalse(world.mail:Model().canSend)
    test.assertFalse(world.mail:RequestSend())

    world.mail:SetBody("Second reminder")
    test.assertEqual(nil, world.mail:Model().progressText)
    test.assertTrue(world.mail:RequestSend())
end)

test.test("guild mail: every recipient starts ticked", function()
    local _, world = newMail()
    readyToSend(world)

    local rows = world.mail:Model().recipients
    test.assertEqual("ann bell-camelot", rows[1].key)
    test.assertTrue(rows[1].checked)
    test.assertTrue(rows[2].checked)
end)

test.test("guild mail: unticking a recipient updates the cost and count", function()
    local addon, world = newMail()
    world.mail:SetRank(2, true)
    world.mail:SetRank(3, true)
    world.mail:SetMode("all")
    test.assertEqual("5 mails to 3 players · Estimated cost: 1s 50c (30c each)", world.mail:Model().costText)

    test.assertTrue(world.mail:SetRecipient("cog wheel-camelot", false))
    local model = world.mail:Model()
    test.assertEqual("4 mails to 3 players · Estimated cost: 1s 20c (30c each)", model.costText)
    test.assertEqual("4 of 5 mails", model.countText)
    test.assertEqual(5, #model.recipients)
    test.assertEqual("Cog Wheel", model.recipients[4].name)
    test.assertFalse(model.recipients[4].checked)

    world.mail:SetRecipient("ann bell-camelot", false)
    test.assertEqual("3 mails to 2 players · Estimated cost: 90c (30c each)", world.mail:Model().costText)
    test.assertFalse(world.mail:SetRecipient("ann bell-camelot", false))

    world.mail:SetRecipient("cog wheel-camelot", true)
    test.assertEqual("4 mails to 3 players · Estimated cost: 1s 20c (30c each)", world.mail:Model().costText)
    test.assertEqual(addon.GuildMail.HINT_NO_SUBJECT, world.mail:Model().hint)
end)

test.test("guild mail: only ticked recipients are sent", function()
    local _, world = newMail()
    readyToSend(world)
    world.mail:SetRecipient("ann bell-camelot", false)

    world.mail:RequestSend()
    test.assertEqual("Send 1 mail for 30c postage?", world.mail:Model().confirmText)
    world.mail:Confirm()
    world.mail:OnSent()

    test.assertEqual(1, #world.sent)
    test.assertEqual("Gus Reed", world.sent[1].to)
    test.assertEqual("Sent 1 of 1 · Postage spent: 30c. Done.", world.mail:Model().progressText)
end)

test.test("guild mail: with everyone unticked, Send waits", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:SetRecipient("ann bell-camelot", false)
    world.mail:SetRecipient("gus reed-camelot", false)

    test.assertEqual(addon.GuildMail.HINT_NONE_TICKED, world.mail:Model().hint)
    test.assertFalse(world.mail:RequestSend())
end)

test.test("guild mail: ticks survive the list being rebuilt, and newcomers start ticked", function()
    local _, world = newMail()
    world.mail:SetRank(2, true)
    world.mail:SetRecipient("ann bell-camelot", false)

    world.mail:SetRank(2, false)
    world.mail:SetRank(3, true)
    world.mail:SetRank(2, true)

    local checked = {}
    local rows = world.mail:Model().recipients
    local index
    for index = 1, #rows do
        checked[rows[index].key] = rows[index].checked
    end
    test.assertFalse(checked["ann bell-camelot"])
    test.assertTrue(checked["gus reed-camelot"])
    test.assertTrue(checked["zed stone-camelot"])
end)

test.test("guild mail: ticks can't change while sending", function()
    local _, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()

    test.assertFalse(world.mail:SetRecipient("gus reed-camelot", false))
    world.mail:OnSent()
    test.assertEqual("Gus Reed", world.sent[2].to)
end)

-- TEMPORARY (#205): remove with the Tester rank.
test.test("guild mail: the temporary Tester rank mails only the testers", function()
    local addon, partition = setup()
    local mail = addon.GuildMail.Create({
        context = function()
            return partition
        end,
        isOfficer = function()
            return true
        end,
        rankNames = function()
            return RANK_NAMES
        end,
        testers = { "Malgen Zelwindran", "Zillatha Zelwindran" },
    })

    local ranks = mail:Model().ranks
    test.assertEqual(addon.GuildMail.TESTER_RANK, ranks[1].index)
    test.assertEqual(5, #ranks)

    mail:SetRank(addon.GuildMail.TESTER_RANK, true)
    mail:SetMode("all")
    local rows = mail:Model().recipients
    test.assertEqual(2, #rows)
    test.assertEqual("Malgen Zelwindran", rows[1].name)
    test.assertEqual("Zillatha Zelwindran", rows[2].name)
    test.assertEqual(addon.GuildMail.TESTER_RANK_NAME, rows[1].rankName)
end)

-- Cost ----------------------------------------------------------------------

test.test("guild mail cost: coins are written like the game's", function()
    local addon = load()

    test.assertEqual("30c", addon.GuildMail.FormatCopper(30))
    test.assertEqual("12s 60c", addon.GuildMail.FormatCopper(1260))
    test.assertEqual("152g 3s", addon.GuildMail.FormatCopper(1520300))
    test.assertEqual("0c", addon.GuildMail.FormatCopper(0))
end)

test.test("guild mail cost: mails and players are counted, and every character costs more", function()
    local addon = load()
    local recipients = {
        { key = "ann bell-camelot", playerId = 2 },
        { key = "cog wheel-camelot", playerId = 2 },
        { key = "zed stone-camelot", playerId = 3 },
    }

    local cost = addon.GuildMail.Cost(recipients, 30, 1000)

    test.assertEqual(3, cost.mails)
    test.assertEqual(2, cost.players)
    test.assertEqual(90, cost.total)
    test.assertFalse(cost.estimated)
end)

test.test("guild mail cost: away from a mailbox the standard 30c is estimated", function()
    local addon = load()

    local cost = addon.GuildMail.Cost({ { key = "a", playerId = 1 } }, nil, nil)

    test.assertEqual(30, cost.perMail)
    test.assertTrue(cost.estimated)
    test.assertTrue(cost.affordable)
end)

test.test("guild mail cost: exactly enough money is enough", function()
    local addon = load()
    local two = { { key = "a", playerId = 1 }, { key = "b", playerId = 2 } }

    test.assertTrue(addon.GuildMail.Cost(two, 30, 60).affordable)
    test.assertFalse(addon.GuildMail.Cost(two, 30, 59).affordable)
end)

test.test("guild mail: the cost line counts mails and players and uses the game's price", function()
    local _, world = newMail()
    world.money = 1520300
    world.mail:SetRank(2, true)
    world.mail:SetRank(3, true)
    world.mail:SetMode("all")

    -- Away from a mailbox: the standard price.
    test.assertEqual("5 mails to 3 players · Estimated cost: 1s 50c (30c each)", world.mail:Model().costText)
    test.assertEqual("You have 152g 3s", world.mail:Model().moneyText)

    world.price = 40
    world.mail:OnMailboxOpened()
    test.assertEqual("5 mails to 3 players · Estimated cost: 2s (40c each)", world.mail:Model().costText)

    world.mail:SetMode("mains")
    test.assertEqual("3 mails to 3 players · Estimated cost: 1s 20c (40c each)", world.mail:Model().costText)
end)

test.test("guild mail: the cost is drawn with the game's coins when it can", function()
    local _, world = newMail({ formatMoney = function(copper)
        return "<" .. copper .. ">"
    end })
    world.mail:SetRank(2, true)

    test.assertEqual("2 mails to 2 players · Estimated cost: <60> (<30> each)", world.mail:Model().costText)
end)

test.test("guild mail: without enough money, the cost turns red and Send is blocked", function()
    local addon, world = newMail()
    readyToSend(world)
    world.money = 59

    local model = world.mail:Model()
    test.assertFalse(model.affordable)
    test.assertFalse(model.canSend)
    test.assertEqual(addon.GuildMail.HINT_NO_MONEY, model.hint)
    test.assertContains(model.costText, "|cffff4040")
    test.assertFalse(world.mail:RequestSend())

    world.money = 60
    test.assertTrue(world.mail:Model().canSend)
end)

test.test("guild mail: retyping the same text changes nothing", function()
    local _, world = newMail()
    readyToSend(world)

    test.assertFalse(world.mail:SetSubject("Launch night"))
    test.assertFalse(world.mail:SetRank(2, true))
end)

-- Window ----------------------------------------------------------------------

local function newWindow()
    local addon = test.newAddon("Core/GuildMailAudience.lua", "Core/GuildMail.lua", "Adapters/GuildMailWindow.lua")
    local environment = FakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local world = { calls = {}, environment = environment }
    local function record(name)
        return function(...)
            table.insert(world.calls, { name = name, args = { ... } })
        end
    end
    world.window = addon.GuildMailWindow.Create({ environment = environment }, {
        onRank = record("rank"),
        onMode = record("mode"),
        onSkipDiscord = record("skipDiscord"),
        onActiveOnly = record("activeOnly"),
        onSubject = record("subject"),
        onRecipient = record("recipient"),
        onSend = record("send"),
        onConfirm = record("confirm"),
        onCancel = record("cancel"),
        onMailboxButton = record("mailbox"),
    })
    return addon, world
end

local MODEL = {
    ranks = {
        { index = 0, name = "Guild Master", checked = false },
        { index = 2, name = "Member", checked = true },
    },
    subject = "Launch night",
    body = "Join us!",
    modes = {
        { id = "mains", label = "Mains only", checked = false },
        { id = "recent", label = "Most recently online character", checked = true },
        { id = "all", label = "Every character", checked = false },
    },
    recipients = {
        { key = "ann bell-camelot", name = "Ann Bell", rank = 2, rankName = "Member", checked = true },
        { key = "cog wheel-camelot", name = "Cog Wheel", playerName = "Annie", rank = 3, rankName = "Initiate",
            lastSeen = "Online", checked = false },
        { key = "gus reed-camelot", name = "Gus Reed", rank = 2, rankName = "Member", checked = true,
            status = "failed", reason = "Mailbox full" },
    },
    countText = "3 mails",
    costText = "3 mails to 2 players · Estimated cost: 90c (30c each)",
    moneyText = "You have 5g",
    skipDiscord = true,
    activeOnly = false,
    canSend = true,
    confirming = false,
    confirmText = "Send 2 mails?",
}

test.test("guild mail window: draws the ranks, the text and the recipients", function()
    local _, world = newWindow()

    world.window:Render(MODEL)

    test.assertEqual("Member", world.window.rankBoxes[2].rankLabel.text)
    test.assertTrue(world.window.rankBoxes[2]:GetChecked())
    test.assertEqual("Launch night", world.window.subject.text)
    test.assertEqual("Join us!", world.window.body.text)
    test.assertEqual("Recipients (3 mails)", world.window.listLabel.text)
    test.assertEqual("3 mails to 2 players · Estimated cost: 90c (30c each)", world.window.cost.text)
    test.assertEqual("You have 5g", world.window.money.text)
    local rows = world.window.recipientRows
    test.assertContains(rows[1].line.text, "Ann Bell")
    test.assertContains(rows[3].line.text, "Mailbox full")
    test.assertEqual("Cog Wheel  |cff999999Annie · Initiate · Online|r", rows[2].line.text)
    test.assertTrue(rows[1]:GetChecked())
    test.assertFalse(rows[2]:GetChecked())
end)

test.test("guild mail window: unticking a recipient is passed back, and extra rows hide", function()
    local _, world = newWindow()
    world.window:Render(MODEL)
    local box = world.window.recipientRows[1]

    box:SetChecked(false)
    box.scripts.OnClick(box)
    test.assertEqual("recipient", world.calls[1].name)
    test.assertEqual("ann bell-camelot", world.calls[1].args[1])
    test.assertFalse(world.calls[1].args[2])

    local shorter = {}
    local key, value
    for key, value in pairs(MODEL) do
        shorter[key] = value
    end
    shorter.recipients = { MODEL.recipients[1] }
    world.window:Render(shorter)
    test.assertTrue(world.window.recipientRows[1].shown)
    test.assertFalse(world.window.recipientRows[2].shown)
    test.assertEqual(nil, rawget(world.window.recipientRows[2], "recipientKey"))
end)

test.test("guild mail window: the skip boxes are drawn and passed back", function()
    local _, world = newWindow()
    world.window:Render(MODEL)

    test.assertTrue(world.window.skipDiscord:GetChecked())
    test.assertFalse(world.window.activeOnly:GetChecked())
    world.window.activeOnly:SetChecked(true)
    world.window.activeOnly.scripts.OnClick(world.window.activeOnly)

    test.assertEqual("activeOnly", world.calls[1].name)
    test.assertTrue(world.calls[1].args[1])
end)

test.test("guild mail window: the Send to choice is drawn and passed back", function()
    local _, world = newWindow()
    world.window:Render(MODEL)

    test.assertFalse(world.window.modeButtons[1]:GetChecked())
    test.assertTrue(world.window.modeButtons[2]:GetChecked())
    world.window.modeButtons[3].scripts.OnClick(world.window.modeButtons[3])

    test.assertEqual("mode", world.calls[1].name)
    test.assertEqual("all", world.calls[1].args[1])
end)

test.test("guild mail window: ticking a rank and pressing Send are passed back", function()
    local _, world = newWindow()
    world.window:Render(MODEL)

    local box = world.window.rankBoxes[1]
    box:SetChecked(true)
    box.scripts.OnClick(box)
    world.window.send.scripts.OnClick(world.window.send)

    test.assertEqual("rank", world.calls[1].name)
    test.assertEqual(0, world.calls[1].args[1])
    test.assertTrue(world.calls[1].args[2])
    test.assertEqual("send", world.calls[2].name)
end)

test.test("guild mail window: typed text is passed back, but text it sets itself isn't", function()
    local _, world = newWindow()
    world.window:Render(MODEL)
    local subject = world.window.subject

    subject.scripts.OnTextChanged(subject, false)
    test.assertEqual(0, #world.calls)
    subject:SetText("Raid tonight")
    subject.scripts.OnTextChanged(subject, true)
    test.assertEqual("subject", world.calls[1].name)
    test.assertEqual("Raid tonight", world.calls[1].args[1])
end)

test.test("guild mail window: preferences and recipients open beside it, one at a time", function()
    local _, world = newWindow()
    world.window:Render(MODEL)
    local preferences, recipients = world.window.preferences, world.window.recipients

    test.assertFalse(preferences.shown)
    test.assertFalse(recipients.shown)
    world.window.editPreferences.scripts.OnClick(world.window.editPreferences)
    test.assertTrue(preferences.shown)

    world.window.editRecipients.scripts.OnClick(world.window.editRecipients)
    test.assertFalse(preferences.shown)
    test.assertTrue(recipients.shown)
    test.assertEqual("Recipients (3 mails)", recipients.heading.text)

    world.window.editRecipients.scripts.OnClick(world.window.editRecipients)
    test.assertFalse(recipients.shown)
end)

test.test("guild mail window: the preferences are summed up beside their Edit button", function()
    local _, world = newWindow()
    world.window:Render(MODEL)

    test.assertEqual("Send to: Most recently online character · Skip Discord names",
        world.window.preferencesText.text)
end)

test.test("guild mail window: the confirmation replaces Send until answered", function()
    local _, world = newWindow()
    local confirming = {}
    local key, value
    for key, value in pairs(MODEL) do
        confirming[key] = value
    end
    confirming.confirming = true

    world.window:Render(confirming)

    test.assertFalse(world.window.send.shown)
    test.assertTrue(world.window.confirm.shown)
    test.assertEqual("Send 2 mails?", world.window.confirmText.text)
    world.window.confirm.scripts.OnClick(world.window.confirm)
    test.assertEqual("confirm", world.calls[1].name)
end)

test.test("guild mail window: the mailbox button is made only for officers, on the Send Mail tab", function()
    local _, world = newWindow()

    test.assertFalse(world.window:ShowMailboxButton(true))
    world.environment.SendMailFrame = world.environment.CreateFrame("Frame", nil, world.environment.UIParent)
    test.assertFalse(world.window:ShowMailboxButton(false))
    test.assertEqual(nil, world.window.mailboxButton)

    test.assertTrue(world.window:ShowMailboxButton(true))
    test.assertTrue(world.window.mailboxButton.shown)
    world.window.mailboxButton.scripts.OnClick(world.window.mailboxButton)
    test.assertEqual("mailbox", world.calls[1].name)

    world.window:ShowMailboxButton(false)
    test.assertFalse(world.window.mailboxButton.shown)
end)

-- Command -----------------------------------------------------------------------

test.test("guild mail: /agf mail tells a non-officer it's for officers", function()
    local world = fixtures.newEnvironment("Forever", {})
    local addon = fixtures.loadAddon(world)
    fixtures.fire(world, "ADDON_LOADED", "AsgardsGuildFellowship")
    world.loggedIn = true
    fixtures.fire(world, "PLAYER_LOGIN")
    local before = #world.messages

    world.environment.SlashCmdList.AGF("mail")

    test.assertContains(world.messages[before + 1], addon.GuildMail.OFFICERS_ONLY)
end)
