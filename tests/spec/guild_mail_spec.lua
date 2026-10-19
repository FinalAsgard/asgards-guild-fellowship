local test = require("tests.test_helper")
local FakeFrames = require("tests.fake_frames")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
        "Core/PlayerService.lua",
        "Core/RosterViewModel.lua",
        "Core/GreetingLibrary.lua",
        "Core/GuildGreet.lua",
        "Core/GuildMailAudience.lua",
        "Core/GuildMailComposer.lua",
        "Core/GuildMailSender.lua",
        "Core/GuildMail.lua",
        "Core/SyncFacts.lua",
        "Core/RecruitConfig.lua",
        "Core/GuildWelcome.lua"
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

test.test("guild mail sender: no answer in time fails the mail, moves on, and tries it again at the end", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)

    world.fire(addon.GuildMailSender.ANSWER_SECONDS)
    local status, reason = world.sender:Status(1)
    test.assertEqual(addon.GuildMailSender.FAILED, status)
    test.assertEqual(addon.GuildMailSender.NO_RESPONSE_RETRY, reason)
    test.assertFalse(world.sender:IsPaused())
    test.assertFalse(world.sender:IsManual())

    world.fire(addon.GuildMailSender.GAP_SECONDS)
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    test.assertEqual("Ann Bell,Gus Reed,Zed Stone,Ann Bell", table.concat(world.sent, ","))
    test.assertEqual(addon.GuildMailSender.PENDING, (world.sender:Status(1)))

    world.sender:OnSent()
    test.assertEqual(addon.GuildMailSender.SENT, (world.sender:Status(1)))
    test.assertEqual(addon.GuildMailSender.DONE, world.sender:Progress().state)
    test.assertEqual(3, world.sender:Progress().sent)
    test.assertEqual(0, world.sender:Progress().failed)
end)

test.test("guild mail sender: a mail with no answer is tried only once more", function()
    local addon, world = newTimedSender()
    world.sender:Start({ MAILS[1] })

    world.fire(addon.GuildMailSender.ANSWER_SECONDS)
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    world.fire(addon.GuildMailSender.ANSWER_SECONDS)
    world.fire(addon.GuildMailSender.GAP_SECONDS)

    test.assertEqual("Ann Bell,Ann Bell", table.concat(world.sent, ","))
    local status, reason = world.sender:Status(1)
    test.assertEqual(addon.GuildMailSender.FAILED, status)
    test.assertEqual(addon.GuildMailSender.NO_RESPONSE, reason)
    test.assertEqual(addon.GuildMailSender.DONE, world.sender:Progress().state)
end)

test.test("guild mail sender: ending after Stop fails for good a mail waiting to be tried again", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)

    world.fire(addon.GuildMailSender.ANSWER_SECONDS)
    test.assertTrue(world.sender:Stop())
    test.assertTrue(world.sender:End())

    local status, reason = world.sender:Status(1)
    test.assertEqual(addon.GuildMailSender.FAILED, status)
    test.assertEqual(addon.GuildMailSender.NO_RESPONSE, reason)
    test.assertEqual(addon.GuildMailSender.PENDING, (world.sender:Status(2)))
    test.assertEqual(addon.GuildMailSender.DONE, world.sender:Progress().state)
end)

test.test("guild mail sender: after a block, every mail waits for a click", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:OnBlocked()
    test.assertTrue(world.sender:IsManual())
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

local CAP = "You have reached the in-game cap of unique mail recipients"

test.test("guild mail sender: the recipient cap pauses on that mail and fails nobody", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)

    test.assertTrue(world.sender:OnError(CAP .. "."))
    test.assertTrue(world.sender:IsPaused())
    test.assertTrue(world.sender:IsCapped())
    test.assertFalse(world.sender:IsManual())
    test.assertEqual(addon.GuildMailSender.PENDING, (world.sender:Status(2)))
    -- The MAIL_FAILED that may follow doesn't fail it, and nothing more goes.
    test.assertFalse(world.sender:OnFailed(nil))
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    world.fire(addon.GuildMailSender.ANSWER_SECONDS)
    test.assertEqual("Ann Bell,Gus Reed", table.concat(world.sent, ","))
    test.assertEqual(0, world.sender:Progress().failed)
end)

test.test("guild mail sender: resuming after the cap retries the refused mail first, and the cap can pause again", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:OnError(CAP)

    test.assertTrue(world.sender:Resume())
    test.assertFalse(world.sender:IsCapped())
    test.assertEqual("Ann Bell,Ann Bell", table.concat(world.sent, ","))
    test.assertTrue(world.sender:OnError(CAP))
    test.assertTrue(world.sender:IsCapped())

    world.sender:Resume()
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    world.sender:OnSent()
    test.assertEqual("Ann Bell,Ann Bell,Ann Bell,Gus Reed,Zed Stone", table.concat(world.sent, ","))
    test.assertEqual(3, world.sender:Progress().sent)
    test.assertEqual(0, world.sender:Progress().failed)
end)

test.test("guild mail sender: the cap after a failure puts that mail back, even the last one", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:OnFailed(nil)

    test.assertTrue(world.sender:OnError(CAP))
    test.assertTrue(world.sender:IsCapped())
    test.assertEqual(addon.GuildMailSender.PENDING, (world.sender:Status(1)))
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    test.assertEqual("Ann Bell", table.concat(world.sent, ","))
    world.sender:Resume()
    test.assertEqual("Ann Bell,Ann Bell", table.concat(world.sent, ","))

    -- The last mail: sending had finished, and isn't any more.
    _, world = newTimedSender()
    world.sender:Start({ MAILS[1] })
    world.sender:OnFailed(nil)
    test.assertEqual(addon.GuildMailSender.DONE, world.sender:Progress().state)
    world.sender:OnError(CAP)
    test.assertTrue(world.sender:IsCapped())
    world.sender:Resume()
    world.sender:OnSent()
    test.assertEqual(1, world.sender:Progress().sent)
    test.assertEqual(addon.GuildMailSender.DONE, world.sender:Progress().state)
end)

test.test("guild mail sender: the client's own cap text is recognized; other errors still fail", function()
    local addon = load()
    local sent = {}
    local sender = addon.GuildMailSender.Create({
        send = function(mail)
            table.insert(sent, mail.to)
            return true
        end,
        capMessage = "Limite de destinataires atteinte.",
    })
    sender:Start(MAILS)
    test.assertTrue(sender:OnError("Limite de destinataires atteinte."))
    test.assertTrue(sender:IsCapped())

    sender:Resume()
    sender:OnError("Cannot find mail recipient.")
    test.assertEqual(addon.GuildMailSender.FAILED, (sender:Status(1)))
    test.assertFalse(sender:IsPaused())
end)

test.test("guild mail sender: Stop while capped stays stopped, and Continue sends the refused mail", function()
    local _, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:OnError(CAP)

    test.assertTrue(world.sender:Stop())
    test.assertTrue(world.sender:IsStopped())
    test.assertTrue(world.sender:Resume())
    test.assertEqual("Ann Bell,Ann Bell", table.concat(world.sent, ","))
end)

test.test("guild mail sender: a restored send waits for Resume, then sends only the pending mails", function()
    local addon, world = newSender()
    local S = addon.GuildMailSender

    test.assertTrue(world.sender:Restore(MAILS, { S.SENT, S.PENDING, S.FAILED }, { nil, nil, "Mailbox full" }))
    test.assertTrue(world.sender:IsStopped())
    test.assertEqual(0, #world.sent)
    local _, reason = world.sender:Status(3)
    test.assertEqual("Mailbox full", reason)

    world.sender:Resume()
    world.sender:OnSent()
    test.assertEqual("Gus Reed", table.concat(world.sent, ","))
    test.assertEqual(S.DONE, world.sender:Progress().state)
    test.assertEqual(2, world.sender:Progress().sent)
end)

test.test("guild mail sender: a restored cap pause is still a pause", function()
    local addon, world = newSender()
    local S = addon.GuildMailSender
    world.sender:Restore(MAILS, { S.SENT, S.PENDING, S.PENDING }, {}, true)

    test.assertTrue(world.sender:IsPaused())
    test.assertTrue(world.sender:IsCapped())
    world.sender:Resume()
    test.assertEqual("Gus Reed", table.concat(world.sent, ","))
end)

test.test("guild mail sender: an unconfirmed mail is passed over until it's settled", function()
    local addon, world = newSender()
    local S = addon.GuildMailSender
    world.sender:Restore(MAILS, { S.UNCONFIRMED, S.PENDING, S.UNCONFIRMED }, {})

    world.sender:Resume()
    world.sender:OnSent()
    test.assertEqual("Gus Reed", table.concat(world.sent, ","))
    test.assertEqual(S.DONE, world.sender:Progress().state)
    test.assertEqual(2, world.sender:Progress().unconfirmed)

    -- Send makes it pending again, and a finished send stops for it.
    test.assertTrue(world.sender:Settle(1, true))
    test.assertTrue(world.sender:IsStopped())
    test.assertTrue(world.sender:Settle(3, false))
    test.assertEqual(S.SKIPPED, (world.sender:Status(3)))
    test.assertFalse(world.sender:Settle(2, true))

    world.sender:Resume()
    world.sender:OnSent()
    test.assertEqual("Gus Reed,Ann Bell", table.concat(world.sent, ","))
    local progress = world.sender:Progress()
    test.assertEqual(2, progress.sent)
    test.assertEqual(1, progress.skipped)
    test.assertEqual(0, progress.unconfirmed)
end)

test.test("guild mail sender: with nothing pending, a restored send is done", function()
    local addon, world = newSender()
    local S = addon.GuildMailSender

    test.assertTrue(world.sender:Restore(MAILS, { S.SENT, S.FAILED, S.SENT }, {}))
    test.assertEqual(S.DONE, world.sender:Progress().state)
    test.assertFalse(world.sender:Resume())
    world.sender:Start(MAILS)
    test.assertFalse(world.sender:Restore(MAILS, {}, {}))
end)

-- Guild Mail ----------------------------------------------------------------

local RANK_NAMES = { "Guild Master", "Officer", "Member", "Initiate" }

-- Stop --------------------------------------------------------------------

test.test("guild mail sender: Stop waits for the mail in flight, then halts", function()
    local addon, world = newSender()
    world.sender:Start(MAILS)

    test.assertTrue(world.sender:Stop())
    test.assertTrue(world.sender:IsStopping())
    test.assertFalse(world.sender:IsStopped())
    world.sender:OnSent()

    test.assertTrue(world.sender:IsStopped())
    test.assertFalse(world.sender:IsSending())
    test.assertEqual("Ann Bell", table.concat(world.sent, ","))
    test.assertEqual(addon.GuildMailSender.SENT, world.sender:Status(1))
    test.assertEqual(addon.GuildMailSender.PENDING, world.sender:Status(2))
end)

test.test("guild mail sender: continuing after Stop sends only the pending mails", function()
    local addon, world = newSender()
    world.sender:Start(MAILS)
    world.sender:Stop()
    world.sender:OnSent()

    test.assertTrue(world.sender:Resume())
    world.sender:OnSent()
    world.sender:OnSent()

    test.assertEqual("Ann Bell,Gus Reed,Zed Stone", table.concat(world.sent, ","))
    test.assertEqual(addon.GuildMailSender.DONE, world.sender:Progress().state)
    test.assertEqual(3, world.sender:Progress().sent)
end)

test.test("guild mail sender: Stop between mails halts before the next one goes", function()
    local _, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:OnSent()

    -- The next mail waits for the gap; Stop comes first.
    test.assertTrue(world.sender:Stop())
    test.assertTrue(world.sender:IsStopped())
    world.fire(1)

    test.assertEqual("Ann Bell", table.concat(world.sent, ","))
end)

test.test("guild mail sender: a stopped mail that never answers fails, and sending stays stopped", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)
    world.sender:Stop()
    world.fire(addon.GuildMailSender.ANSWER_SECONDS)

    test.assertTrue(world.sender:IsStopped())
    test.assertEqual(addon.GuildMailSender.FAILED, (world.sender:Status(1)))
    test.assertEqual(1, #world.sent)

    -- Continuing tries it again at the end.
    world.sender:Resume()
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    world.sender:OnSent()
    world.fire(addon.GuildMailSender.GAP_SECONDS)
    test.assertEqual("Ann Bell,Gus Reed,Zed Stone,Ann Bell", table.concat(world.sent, ","))
end)

test.test("guild mail sender: End gives up on the pending mails", function()
    local addon, world = newSender()
    world.sender:Start(MAILS)
    world.sender:Stop()
    world.sender:OnSent()

    test.assertTrue(world.sender:End())
    test.assertEqual(addon.GuildMailSender.DONE, world.sender:Progress().state)
    test.assertEqual(addon.GuildMailSender.PENDING, world.sender:Status(2))
    test.assertFalse(world.sender:Resume())
    test.assertFalse(world.sender:Stop())
end)

test.test("guild mail sender: a rejected mail fails with its reason and sending carries on", function()
    local addon, world = newTimedSender()
    world.sender:Start(MAILS)

    world.sender:OnFailed()
    world.sender:OnError("Cannot find mail recipient.")
    world.fire(1)

    test.assertEqual("Ann Bell,Gus Reed", table.concat(world.sent, ","))
    local status, reason = world.sender:Status(1)
    test.assertEqual(addon.GuildMailSender.FAILED, status)
    test.assertEqual("Cannot find mail recipient.", reason)
end)

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
            return overrides.selfKey or "tool box-camelot"
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
        loadDraft = function()
            return world.saved
        end,
        saveDraft = function(draft)
            world.saved = draft
        end,
        outbox = function()
            return world.outbox
        end,
        now = function()
            return world.time or 5000
        end,
        view = world.view,
        welcome = addon.GuildWelcome.Create({
            partition = function()
                return partition
            end,
            selfKey = function()
                return "tool box-camelot"
            end,
            isOfficer = function()
                return world.officer
            end,
            -- Ann Bell's add-on is another officer's; Cog Wheel isn't one.
            senderIsOfficer = function(sender)
                return sender == "Ann Bell"
            end,
            isOwn = function(sender)
                return sender == "Tool Box"
            end,
            keyOf = function(rawName)
                return string.lower(rawName) .. "-camelot"
            end,
            onWelcomed = function(key, main)
                world.mail:OnWelcomedElsewhere(key, main)
            end,
            now = function()
                return world.time or 5000
            end,
            announce = function(message)
                world.announced = world.announced or {}
                table.insert(world.announced, message)
                return true
            end,
        }),
    })
    world.saved = overrides.saved
    world.outbox = overrides.outbox or {}
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
    test.assertFalse(world.mail:ShowsMailboxTab())
end)

test.test("guild mail: an officer opens it beside the mailbox or anywhere", function()
    local _, world = newMail()

    test.assertTrue(world.mail:ShowsMailboxTab())
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
    test.assertEqual("Sent 2 · Failed 0 · Postage spent: 60c", world.view.model.progressText)
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

test.test("guild mail: at the game's mail limit, sending pauses and Send becomes Resume", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()

    test.assertTrue(world.mail:OnError("You have reached the in-game cap of unique mail recipients"))
    local model = world.mail:Model()
    test.assertEqual(addon.GuildMail.HINT_CAPPED, model.hint)
    test.assertEqual(addon.GuildMail.RESUME_TEXT, model.sendText)
    test.assertTrue(model.canSend)
    test.assertEqual(addon.GuildMailSender.PENDING, model.recipients[1].status)

    test.assertTrue(world.mail:RequestSend())
    test.assertEqual(2, #world.sent)
    test.assertEqual("Ann Bell", world.sent[2].to)
end)

test.test("guild mail: a send to more characters than the game's limit is warned before it goes", function()
    local addon, world = newMail()
    readyToSend(world)

    world.mail:RequestSend()
    test.assertEqual(nil, world.mail:Model().confirmWarning)

    -- Two recipients: warned from a limit of two.
    addon.GuildMail.RECIPIENT_CAP = 2
    test.assertEqual("The game lets you mail about 2 different characters at a time."
        .. " The rest will wait for you to resume them later.", world.mail:Model().confirmWarning)
    addon.GuildMail.RECIPIENT_CAP = 3
    test.assertEqual(nil, world.mail:Model().confirmWarning)
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
    test.assertEqual("Sent 1 · Failed 0 · Postage spent: 30c", world.mail:Model().progressText)
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

test.test("guild mail: Stop halts the send, and Continue sends only to the rest", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:SetRank(3, true)
    world.mail:RequestSend()
    world.mail:Confirm()

    local model = world.mail:Model()
    test.assertEqual(addon.GuildMail.STOP_TEXT, model.stopText)
    test.assertTrue(model.canStop)
    test.assertTrue(world.mail:Stop())
    test.assertEqual(addon.GuildMail.HINT_STOPPING, world.mail:Model().hint)
    test.assertFalse(world.mail:Model().canStop)
    world.mail:OnSent()

    model = world.mail:Model()
    test.assertEqual(addon.GuildMail.HINT_STOPPED, model.hint)
    test.assertEqual(addon.GuildMail.CONTINUE_TEXT, model.sendText)
    test.assertEqual(addon.GuildMail.END_TEXT, model.stopText)
    test.assertTrue(model.canSend)
    test.assertTrue(model.sending)
    test.assertEqual(addon.GuildMailSender.SENT, model.recipients[1].status)
    test.assertFalse(world.mail:SetSubject("Changed"))
    test.assertFalse(world.mail:SetRank(2, false))

    test.assertTrue(world.mail:RequestSend())
    world.mail:OnSent()
    world.mail:OnSent()
    test.assertEqual("Ann Bell,Gus Reed,Zed Stone", world.sent[1].to .. "," .. world.sent[2].to .. "," .. world.sent[3].to)
    test.assertEqual(3, #world.sent)
    test.assertEqual("Sent 3 · Failed 0 · Postage spent: 90c", world.mail:Model().progressText)
end)

test.test("guild mail: closing the mailbox stops sending, and reopening it keeps the progress", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()

    world.mail:OnMailboxClosed()
    world.mail:OnSent()
    test.assertEqual(1, #world.sent)
    test.assertEqual(addon.GuildMail.HINT_NO_MAILBOX, world.mail:Model().hint)
    test.assertFalse(world.mail:Model().canSend)
    test.assertFalse(world.mail:RequestSend())

    world.mail:OnMailboxOpened()
    test.assertEqual("Sent 1 of 2 · Postage spent: 30c", world.mail:Model().progressText)
    test.assertTrue(world.mail:RequestSend())
    test.assertEqual("Gus Reed", world.sent[2].to)
end)

test.test("guild mail: End finishes a stopped send, and failures stay listed in the summary", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:SetRank(3, true)
    world.mail:RequestSend()
    world.mail:Confirm()
    world.mail:OnFailed("Mailbox full")
    world.mail:Stop()
    world.mail:OnSent()

    test.assertTrue(world.mail:End())
    local model = world.mail:Model()
    test.assertEqual("Sent 1 · Failed 1 · Postage spent: 30c", model.progressText)
    test.assertEqual(addon.GuildMailSender.FAILED, model.recipients[1].status)
    test.assertEqual("Mailbox full", model.recipients[1].reason)
    test.assertEqual(nil, model.stopText)
    test.assertFalse(model.sending)
    test.assertTrue(world.mail:SetBody("Changed"))
end)

-- Composer ------------------------------------------------------------------

local function foreverNormalizer(addon)
    return addon.NameNormalizer.Create({ twoPartNames = true, homeRealm = "Camelot" })
end

local function cogWheel()
    return { key = "cog wheel-camelot", name = "Cog Wheel" }
end

test.test("guild mail composer: every placeholder is filled in, in any case", function()
    local addon, partition = setup()
    partition:SetAlias(partition:GetCharacter("ann bell-camelot").player, "Annie", "ann bell-camelot")

    local mail = addon.GuildMailComposer.Compose("Hi {NAME}",
        "{name}|{main}|{MainFirst}|{mainlast}|{character}|{CHARACTERFIRST}|{characterLast}|{other}",
        cogWheel(), partition, foreverNormalizer(addon))

    test.assertEqual("Hi Annie", mail.subject)
    test.assertEqual("Annie|Ann Bell|Ann|Bell|Cog Wheel|Cog|Wheel|{other}", mail.body)
    test.assertEqual(nil, mail.warning)
end)

test.test("guild mail composer: {character} is the character mailed, and {name} is the main without an alias", function()
    local addon, partition = setup()

    local mail = addon.GuildMailComposer.Compose("{character}", "{name} / {main}", cogWheel(), partition,
        foreverNormalizer(addon))

    test.assertEqual("Cog Wheel", mail.subject)
    test.assertEqual("Ann Bell / Ann Bell", mail.body)
end)

test.test("guild mail composer: one-word names fill first and last parts with the whole name", function()
    local addon, partition = setup()

    local mail = addon.GuildMailComposer.Compose("{mainFirst}", "{characterLast}", cogWheel(), partition, nil)

    test.assertEqual("Ann Bell", mail.subject)
    test.assertEqual("Cog Wheel", mail.body)
end)

test.test("guild mail composer: a filled-in subject over 64 or message over 500 letters is flagged", function()
    local addon, partition = setup()
    local compose = function(subject, body)
        return addon.GuildMailComposer.Compose(subject, body, cogWheel(), partition, nil)
    end

    test.assertEqual(nil, compose(string.rep("a", 64), string.rep("b", 500)).warning)
    test.assertEqual("subject too long (65/64)", compose(string.rep("a", 65), "").warning)
    test.assertEqual("message too long (501/500)", compose("", string.rep("b", 501)).warning)
    -- "Cog Wheel" is 9 letters: 56 + 9 = 65.
    test.assertEqual("subject too long (65/64)", compose(string.rep("a", 56) .. "{character}", "").warning)
    -- Letters, not bytes: "é" is two bytes but one letter.
    test.assertEqual(nil, compose(string.rep("\195\169", 64), "").warning)
    test.assertEqual(64, addon.GuildMailComposer.Letters(string.rep("\195\169", 64)))
end)

test.test("guild mail: each mail is filled in for its recipient", function()
    local _, world = newMail()
    readyToSend(world)
    world.mail:SetSubject("News for {name}")
    world.mail:SetBody("Hi {character}!")

    world.mail:RequestSend()
    world.mail:Confirm()
    world.mail:OnSent()

    test.assertEqual("News for Ann Bell", world.sent[1].subject)
    test.assertEqual("Hi Ann Bell!", world.sent[1].body)
    test.assertEqual("News for Gus Reed", world.sent[2].subject)
end)

test.test("guild mail: the preview shows the mail as the first ticked recipient gets it", function()
    local _, world = newMail()
    readyToSend(world)
    world.mail:SetBody("Hi {character}!")

    test.assertEqual("Ann Bell", world.mail:Model().preview.to)
    test.assertEqual("Hi Ann Bell!", world.mail:Model().preview.body)

    world.mail:SetRecipient("ann bell-camelot", false)
    test.assertEqual("Gus Reed", world.mail:Model().preview.to)
    test.assertEqual("Launch night", world.mail:Model().preview.subject)

    world.mail:SetRecipient("gus reed-camelot", false)
    test.assertEqual(nil, world.mail:Model().preview)
end)

test.test("guild mail: a recipient whose mail is too long is warned about and unticked", function()
    local _, world = newMail()
    readyToSend(world)
    -- 56 letters plus {name}: "Ann Bell" (8) makes 64 and fits; the alias
    -- "Gus the Great" (13) makes 69.
    world.partition:SetAlias(world.partition:GetCharacter("gus reed-camelot").player, "Gus the Great", "gus reed-camelot")
    world.mail:SetSubject(string.rep("a", 56) .. "{name}")

    local rows = world.mail:Model().recipients
    test.assertEqual("Ann Bell", rows[1].name)
    test.assertTrue(rows[1].checked)
    test.assertEqual(nil, rows[1].warning)
    test.assertFalse(rows[2].checked)
    test.assertEqual("subject too long (69/64)", rows[2].warning)
    test.assertEqual("1 of 2 mails", world.mail:Model().countText)
    test.assertContains(world.mail:Model().costText, "1 mail to 1 player")

    world.mail:RequestSend()
    world.mail:Confirm()
    test.assertEqual(1, #world.sent)
    test.assertEqual("Ann Bell", world.sent[1].to)
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
    local addon = test.newAddon("Core/GuildMailAudience.lua", "Core/GuildMailComposer.lua", "Core/GuildMail.lua",
        "Adapters/GuildMailWindow.lua")
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
        onStop = record("stop"),
        onEnd = record("end"),
        onBack = record("back"),
        onResumeEntry = record("resumeEntry"),
        onCancelEntry = record("cancelEntry"),
        onRemoveEntry = record("removeEntry"),
        onSettle = record("settle"),
        onWelcomeSubject = record("welcomeSubject"),
        onWelcomeBody = record("welcomeBody"),
        onWelcomeSave = record("welcomeSave"),
        onWelcomeOn = record("welcomeOn"),
        onWelcomeBack = record("welcomeBack"),
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

test.test("guild mail window: Stop shows while sending, becomes End, and shows the hint under progress", function()
    local _, world = newWindow()
    world.window:Render(MODEL)
    test.assertFalse(world.window.stop.shown)

    local sending = {}
    local key, value
    for key, value in pairs(MODEL) do
        sending[key] = value
    end
    sending.stopText, sending.canStop = "Stop", true
    sending.progressText, sending.hint = "Sent 1 of 3", "Stopping after this mail..."
    world.window:Render(sending)
    test.assertTrue(world.window.stop.shown)
    test.assertEqual("Sent 1 of 3\nStopping after this mail...", world.window.status.text)
    world.window.stop.scripts.OnClick(world.window.stop)
    test.assertEqual("stop", world.calls[1].name)

    sending.stopText = "End"
    world.window:Render(sending)
    world.window.stop.scripts.OnClick(world.window.stop)
    test.assertEqual("end", world.calls[2].name)
end)

test.test("guild mail window: the preview panel shows the first recipient's mail, and warnings show on rows", function()
    local _, world = newWindow()
    local model = {}
    local key, value
    for key, value in pairs(MODEL) do
        model[key] = value
    end
    model.preview = { to = "Ann Bell", subject = "Hi Ann Bell", body = "See you tonight!" }
    model.recipients = {
        { key = "ann bell-camelot", name = "Ann Bell", rank = 2, rankName = "Member", checked = false,
            warning = "subject too long (65/64)" },
    }

    world.window:Render(model)
    world.window.editPreview.scripts.OnClick(world.window.editPreview)

    test.assertTrue(world.window.preview.shown)
    test.assertEqual("To: Ann Bell", world.window.previewTo.text)
    test.assertEqual("Subject: Hi Ann Bell", world.window.previewSubject.text)
    test.assertEqual("See you tonight!", world.window.previewBody.text)
    test.assertContains(world.window.recipientRows[1].line.text, "subject too long (65/64)")

    model.preview = nil
    world.window:Render(model)
    test.assertEqual("Nobody is ticked to preview.", world.window.previewTo.text)
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

test.test("guild mail window: a sent mail on view is drawn read-only, with its buttons passed back", function()
    local _, world = newWindow()
    local model = {}
    local key, value
    for key, value in pairs(MODEL) do
        model[key] = value
    end
    model.entry = {
        position = 2,
        subject = "Launch night",
        body = "Hi {name}",
        stateText = "Stopped",
        progressText = "Sent 1 of 2, 1 unconfirmed",
        whenText = "3 h ago",
        preview = { to = "Ann Bell", subject = "Launch night", body = "Hi Ann Bell" },
        recipients = {
            { name = "Ann Bell", rankName = "Member", status = "sent" },
            { name = "Gus Reed", rankName = "Member", status = "unconfirmed", canSettle = true },
        },
        canResume = true,
        canCancel = true,
        canRemove = false,
    }

    world.window:Render(model)
    test.assertTrue(world.window.entryFrame.shown)
    test.assertEqual("Subject: Launch night", world.window.entrySubject.text)
    test.assertEqual("Stopped · Sent 1 of 2, 1 unconfirmed · sent 3 h ago", world.window.entryState.text)
    test.assertEqual("Hi Ann Bell", world.window.entryBody.text)
    test.assertContains(world.window.entryRows[1].line.text, "sent")
    test.assertFalse(world.window.entryRows[1].send.shown)
    test.assertTrue(world.window.entryRows[2].send.shown)
    test.assertFalse(world.window.entryRemove.shown)

    world.window.entryRows[2].skip.scripts.OnClick(world.window.entryRows[2].skip)
    world.window.entryResume.scripts.OnClick(world.window.entryResume)
    world.window.entryCancel.scripts.OnClick(world.window.entryCancel)
    world.window.entryBack.scripts.OnClick(world.window.entryBack)
    test.assertEqual("settle", world.calls[1].name)
    test.assertEqual(2, world.calls[1].args[1])
    test.assertFalse(world.calls[1].args[2])
    test.assertEqual("resumeEntry", world.calls[2].name)
    test.assertEqual(2, world.calls[2].args[1])
    test.assertEqual("cancelEntry", world.calls[3].name)
    test.assertEqual("back", world.calls[4].name)

    model.entry = nil
    world.window:Render(model)
    test.assertFalse(world.window.entryFrame.shown)
end)

-- Mailbox tab -----------------------------------------------------------------

local function newTab(environmentOverrides)
    local addon = test.newAddon("Adapters/MailboxTab.lua")
    local environment = FakeFrames.install({})
    environment.UIParent = environment.CreateFrame("Frame", nil, nil)
    local world = { calls = {}, environment = environment }
    local key, value
    for key, value in pairs(environmentOverrides or {}) do
        environment[key] = value
    end
    local function record(name)
        return function(...)
            table.insert(world.calls, { name = name, args = { ... } })
        end
    end
    world.tab = addon.MailboxTab.Create({ environment = environment }, {
        onNew = record("new"),
        onEdit = record("edit"),
        onView = record("view"),
        onResume = record("resume"),
        onCancel = record("cancel"),
        onRemove = record("remove"),
        onConfirm = record("confirm"),
        onDismiss = record("dismiss"),
        onShown = record("shown"),
    })
    return addon, world
end

-- A mailbox with its two tabs and pages.
local function mailbox(environment)
    environment.MailFrame = environment.CreateFrame("Frame", nil, environment.UIParent)
    environment.MailFrameTab1 = environment.CreateFrame("Button", nil, environment.MailFrame)
    environment.MailFrameTab2 = environment.CreateFrame("Button", nil, environment.MailFrame)
    environment.InboxFrame = environment.CreateFrame("Frame", nil, environment.MailFrame)
    environment.SendMailFrame = environment.CreateFrame("Frame", nil, environment.MailFrame)
    environment.hooks = {}
    environment.hooksecurefunc = function(name, hook)
        environment.hooks[name] = hook
    end
end

local OUTBOX = {
    draft = { subject = "Raid night" },
    entries = {
        { position = 2, subject = "Launch night", progressText = "Sent 19 of 42", whenText = "2 h ago",
            state = "paused", stateText = "Paused at the mail limit", canResume = true, canCancel = true },
        { position = 1, subject = "Rules", progressText = "Sent 5 of 5", state = "done", stateText = "Done",
            canRemove = true },
    },
    canNew = true,
}

test.test("mailbox tab: only officers get it, and only beside the mailbox's tabs", function()
    local _, world = newTab()

    test.assertFalse(world.tab:Install(true))
    test.assertTrue(world.tab:Install(false))
    mailbox(world.environment)
    test.assertTrue(world.tab:Install(true))
    test.assertEqual("Guild Mail", world.tab.tab.text)
    test.assertTrue(world.tab.tab.shown)
    world.tab:Install(false)
    test.assertFalse(world.tab.tab.shown)
end)

test.test("mailbox tab: clicking it shows its page over the inbox; the game's tabs hide it", function()
    local _, world = newTab()
    mailbox(world.environment)
    world.tab:Install(true)
    test.assertFalse(world.tab:IsShown())

    world.tab.tab.scripts.OnClick(world.tab.tab)
    test.assertTrue(world.tab:IsShown())
    test.assertFalse(world.environment.InboxFrame.shown)
    test.assertFalse(world.environment.SendMailFrame.shown)
    test.assertEqual("shown", world.calls[1].name)

    world.environment.hooks.MailFrameTab_OnClick()
    test.assertFalse(world.tab:IsShown())
end)

test.test("mailbox tab: its page hides on the game's own tab clicks, and when the mailbox opens again", function()
    local _, world = newTab()
    mailbox(world.environment)
    world.tab:Install(true)

    world.tab.tab.scripts.OnClick(world.tab.tab)
    test.assertTrue(world.tab:IsShown())
    -- Inbox clicked on a client without MailFrameTab_OnClick: the tab's own
    -- OnClick still hides the page.
    world.environment.MailFrameTab1.hooks.OnClick(world.environment.MailFrameTab1)
    test.assertFalse(world.tab:IsShown())
    test.assertFalse(world.tab.page.shown)

    -- Left up when the mailbox closed: the next opening is on the game's page.
    world.tab.tab.scripts.OnClick(world.tab.tab)
    test.assertTrue(world.tab:IsShown())
    world.tab:Install(true)
    test.assertFalse(world.tab:IsShown())
    test.assertFalse(world.tab.page.shown)
end)

test.test("mailbox tab: a client whose tab can't be built gets none, and nothing half-made", function()
    local _, world = newTab()
    mailbox(world.environment)
    world.environment.MailFrame.GetFrameLevel = function()
        error("no frame levels here")
    end

    test.assertFalse(world.tab:Install(true))
    test.assertEqual(nil, world.tab.tab)
    test.assertEqual(nil, world.tab.page)
end)

-- Records every SetPoint and SetAllPoints on frames made from now on, as
-- `frame.points`.
local function recordPoints(environment)
    local create = environment.CreateFrame
    environment.CreateFrame = function(...)
        local frame = create(...)
        rawset(frame, "points", {})
        rawset(frame, "SetPoint", function(self, ...)
            table.insert(self.points, { ... })
        end)
        rawset(frame, "SetAllPoints", function(self, target)
            table.insert(self.points, { "ALL", target })
        end)
        return frame
    end
end

test.test("mailbox tab: sits level with the game's tabs, and its page stays below the header", function()
    local _, world = newTab()
    mailbox(world.environment)
    local inbox, send = world.environment.MailFrameTab1, world.environment.MailFrameTab2
    rawset(send, "GetPoint", function()
        return "TOPLEFT", inbox, "TOPRIGHT", 3, 0
    end)
    recordPoints(world.environment)
    world.tab:Install(true)

    local point = world.tab.tab.points[1]
    test.assertEqual("TOPLEFT", point[1])
    test.assertEqual(send, point[2])
    test.assertEqual("TOPRIGHT", point[3])
    test.assertEqual(3, point[4])
    -- No content area here: below the title bar and mail icon.
    local top = world.tab.page.points[1]
    test.assertEqual("TOPLEFT", top[1])
    test.assertEqual(world.environment.InboxFrame, top[2])
    test.assertEqual(-64, top[5])

    -- A client with the mailbox's content area puts the page in it.
    local _, other = newTab()
    mailbox(other.environment)
    local inset = other.environment.CreateFrame("Frame", nil, other.environment.MailFrame)
    rawset(other.environment.MailFrame, "Inset", inset)
    recordPoints(other.environment)
    other.tab:Install(true)
    test.assertEqual("ALL", other.tab.page.points[1][1])
    test.assertEqual(inset, other.tab.page.points[1][2])
end)

test.test("mailbox tab: a row's text runs up to its buttons shown, on one line", function()
    local _, world = newTab()
    mailbox(world.environment)
    world.tab:Install(true)
    world.tab:Render(OUTBOX)

    -- The text's last anchor is its right edge.
    local function edge(line)
        local points = line.points or {}
        return points[#points] and points[#points][2]
    end
    local draft, mail = world.tab.rows[1], world.tab.rows[2]
    for _, line in ipairs({ draft.title, draft.detail, mail.title }) do
        rawset(line, "points", {})
        rawset(line, "SetPoint", function(self, ...)
            table.insert(self.points, { ... })
        end)
    end
    world.tab:Render(OUTBOX)

    -- The draft has only Edit: its text reaches Edit, not the empty slots.
    test.assertEqual(draft.buttons[3], edge(draft.title))
    test.assertEqual(draft.buttons[3], edge(draft.detail))
    test.assertEqual(mail.buttons[1], edge(mail.title))
    test.assertFalse(draft.title.wordWrap)
    test.assertFalse(draft.detail.wordWrap)
end)

test.test("mailbox tab: lists the draft and the guild mails, newest first, with their buttons", function()
    local _, world = newTab()
    mailbox(world.environment)
    world.tab:Install(true)
    world.tab.tab.scripts.OnClick(world.tab.tab)
    world.tab:Render(OUTBOX)

    local rows = world.tab.rows
    test.assertEqual("Raid night", rows[1].title.text)
    test.assertEqual("Edit", rows[1].buttons[3].text)
    test.assertFalse(rows[1].buttons[1].shown)
    test.assertEqual("Launch night  |cff999999Paused at the mail limit|r", rows[2].title.text)
    test.assertEqual("Sent 19 of 42 · 2 h ago", rows[2].detail.text)
    test.assertEqual("View", rows[2].buttons[1].text)
    test.assertEqual("Resume", rows[2].buttons[2].text)
    test.assertEqual("Cancel", rows[2].buttons[3].text)
    test.assertEqual("Remove", rows[3].buttons[3].text)
    test.assertFalse(world.tab.empty.shown)
    test.assertFalse(world.tab.yes.shown)

    rows[1].buttons[3].scripts.OnClick(rows[1].buttons[3])
    rows[2].buttons[1].scripts.OnClick(rows[2].buttons[1])
    rows[2].buttons[2].scripts.OnClick(rows[2].buttons[2])
    rows[3].buttons[3].scripts.OnClick(rows[3].buttons[3])
    world.tab.new.scripts.OnClick(world.tab.new)
    local names = {}
    local index
    for index = 2, #world.calls do
        table.insert(names, world.calls[index].name .. tostring(world.calls[index].args[1] or ""))
    end
    test.assertEqual("edit,view2,resume2,remove1,new", table.concat(names, ","))
end)

test.test("mailbox tab: a question waits for Yes or No, and an empty list says so", function()
    local _, world = newTab()
    mailbox(world.environment)
    world.tab:Install(true)

    world.tab:Render({ entries = {}, canNew = true, actionText = "Discard the current draft?" })
    test.assertTrue(world.tab.empty.shown)
    test.assertEqual("Discard the current draft?", world.tab.question.text)
    test.assertTrue(world.tab.yes.shown)
    world.tab.yes.scripts.OnClick(world.tab.yes)
    world.tab.no.scripts.OnClick(world.tab.no)
    test.assertEqual("confirm", world.calls[1].name)
    test.assertEqual("dismiss", world.calls[2].name)
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

-- Saved draft ---------------------------------------------------------------

test.test("guild mail: the draft and filter choices are saved as they change", function()
    local _, world = newMail()
    world.mail:Open(false)
    world.mail:SetRank(2, true)
    world.mail:SetRank(3, true)
    world.mail:SetMode("all")
    world.mail:SetSkipDiscord(true)
    world.mail:SetActiveOnly(true)
    world.mail:SetSubject("Launch night")
    world.mail:SetBody("Hi {name}!")

    test.assertEqual("Launch night", world.saved.subject)
    test.assertEqual("Hi {name}!", world.saved.body)
    test.assertEqual("2,3", table.concat(world.saved.ranks, ","))
    test.assertEqual("all", world.saved.mode)
    test.assertTrue(world.saved.skipDiscord)
    test.assertTrue(world.saved.activeOnly)
end)

test.test("guild mail: the saved draft is back when the window opens", function()
    local _, world = newMail({
        saved = {
            subject = "Launch night", body = "Hi {name}!", ranks = { 2 },
            mode = "recent", skipDiscord = true, activeOnly = false,
        },
    })

    world.mail:Open(false)
    local model = world.view.model

    test.assertEqual("Launch night", model.subject)
    test.assertEqual("Hi {name}!", model.body)
    test.assertTrue(model.ranks[3].checked)
    test.assertFalse(model.ranks[2].checked)
    test.assertTrue(model.modes[2].checked)
    test.assertTrue(model.skipDiscord)
    test.assertFalse(model.activeOnly)
end)

test.test("guild mail: the draft is restored once, never over changes", function()
    local _, world = newMail({ saved = { subject = "Old", ranks = {} } })
    world.mail:Open(false)
    world.mail:SetSubject("New")
    world.saved = { subject = "Old", ranks = {} }

    world.mail:Open(false)

    test.assertEqual("New", world.view.model.subject)
end)

test.test("guild mail: unticked recipients are saved with the draft and come back after a reload", function()
    local _, world = newMail()
    world.mail:Open(false)
    readyToSend(world)
    local key = world.view.model.recipients[1].key
    world.mail:SetRecipient(key, false)

    test.assertEqual("Launch night", world.saved.subject)
    test.assertEqual(key, table.concat(world.saved.unticked, ","))
    test.assertEqual(nil, rawget(world.saved, "recipients"))

    local _, reloaded = newMail({ saved = world.saved })
    reloaded.mail:Open(false)
    test.assertFalse(reloaded.view.model.recipients[1].checked)
    test.assertTrue(reloaded.view.model.recipients[2].checked)
    test.assertEqual("1 of 2 mails", reloaded.view.model.countText)
    test.assertEqual(nil, reloaded.view.model.progressText)

    -- Ticking them again is saved too, and New starts with everyone ticked.
    reloaded.mail:SetRecipient(key, true)
    test.assertEqual(0, #reloaded.saved.unticked)
    reloaded.mail:SetRecipient(key, false)
    reloaded.mail:RequestNew()
    reloaded.mail:ConfirmAction()
    test.assertEqual(0, #reloaded.saved.unticked)
end)

test.test("guild mail: a saved rank the guild no longer has is ignored", function()
    local addon, world = newMail({ saved = { subject = "Hi", ranks = { 9 } } })

    world.mail:Open(false)

    test.assertEqual(addon.GuildMail.HINT_NO_RANKS, world.view.model.hint)
    test.assertEqual(0, #world.view.model.recipients)
    test.assertEqual(4, #world.view.model.ranks)

    world.mail:SetRank(2, true)
    test.assertTrue(#world.view.model.recipients > 0)
end)

test.test("guild mail: an unknown saved Send to choice is ignored", function()
    local _, world = newMail({ saved = { mode = "everyone", ranks = { 2 } } })

    world.mail:Open(false)

    test.assertTrue(world.view.model.modes[1].checked)
end)

-- Events during the send call ---------------------------------------------

test.test("guild mail sender: a send the game blocks while SendMail runs pauses for a click", function()
    local world
    local _, made = newSender(function()
        if #world.sent == 1 then
            world.sender:OnBlocked()
        end
        return true
    end)
    world = made

    world.sender:Start(MAILS)

    test.assertTrue(world.sender:IsPaused())
    test.assertTrue(world.sender:IsManual())
    test.assertEqual(1, #world.sent)
    -- No late answer is taken for the blocked mail.
    test.assertFalse(world.sender:OnSent())

    test.assertTrue(world.sender:Resume())
    test.assertEqual("Ann Bell,Ann Bell", table.concat(world.sent, ","))
end)

test.test("guild mail sender: an error while SendMail runs fails that mail and moves on", function()
    local world
    local addon, made = newSender(function()
        if #world.sent == 1 then
            world.sender:OnError("Please enter a full character name.")
        end
        return true
    end)
    world = made

    world.sender:Start(MAILS)

    local status, reason = world.sender:Status(1)
    test.assertEqual(addon.GuildMailSender.FAILED, status)
    test.assertEqual("Please enter a full character name.", reason)
    test.assertEqual("Ann Bell,Gus Reed", table.concat(world.sent, ","))
    test.assertTrue(world.sender:OnSent())
    test.assertEqual(addon.GuildMailSender.SENT, (world.sender:Status(2)))
end)

-- Outbox --------------------------------------------------------------------

-- Starts a send of the two Members' mails and answers the first.
local function sendOne(world)
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()
    world.mail:OnSent()
end

-- The same account after a reload: a new Guild Mail on the saved outbox.
local function reload(world, overrides)
    overrides = overrides or {}
    overrides.outbox = world.outbox
    local addon, after = newMail(overrides)
    after.mail:OnMailboxOpened()
    return addon, after
end

test.test("guild mail outbox: Send saves the send, and each answer as it comes", function()
    local addon, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()

    test.assertEqual(1, #world.outbox)
    local entry = world.outbox[1]
    test.assertEqual("Launch night", entry.subject)
    test.assertEqual("Join us on Discord!", entry.body)
    test.assertEqual("tool box-camelot", entry.by)
    test.assertEqual(5000, entry.at)
    test.assertEqual(30, entry.perMail)
    test.assertEqual(addon.GuildMailSender.SENDING, entry.state)
    test.assertEqual("Ann Bell", entry.recipients[1].name)
    test.assertEqual("Join us on Discord!", entry.recipients[1].body)
    test.assertTrue(entry.recipients[1].inFlight)

    world.mail:OnSent()
    test.assertEqual(addon.GuildMailSender.SENT, entry.recipients[1].status)
    test.assertEqual(nil, entry.recipients[1].inFlight)
    test.assertTrue(entry.recipients[2].inFlight)
    world.mail:OnFailed("Mailbox full")
    test.assertEqual(addon.GuildMailSender.FAILED, entry.recipients[2].status)
    test.assertEqual("Mailbox full", entry.recipients[2].reason)
    test.assertEqual(addon.GuildMailSender.DONE, entry.state)
end)

test.test("guild mail outbox: a saved send can't be changed, and a new send gets its own entry", function()
    local _, world = newMail()
    sendOne(world)
    world.mail:OnSent()

    test.assertTrue(world.mail:SetSubject("Raid night"))
    test.assertEqual("Launch night", world.outbox[1].subject)
    world.mail:RequestSend()
    world.mail:Confirm()
    test.assertEqual(2, #world.outbox)
    test.assertEqual("Raid night", world.outbox[2].subject)
    test.assertEqual("Launch night", world.outbox[1].subject)
end)

test.test("guild mail outbox: after a reload the send comes back and continues with nobody mailed twice", function()
    local _, world = newMail()
    sendOne(world)
    -- The game closes after the first answer, between mails.
    world.outbox[1].recipients[2].inFlight = nil

    local addon, after = reload(world)
    after.mail:Open(true)
    local model = after.view.model
    test.assertEqual(addon.GuildMailSender.SENT, model.recipients[1].status)
    test.assertEqual(addon.GuildMailSender.PENDING, model.recipients[2].status)
    test.assertEqual(addon.GuildMail.CONTINUE_TEXT, model.sendText)
    test.assertEqual(0, #after.sent)

    test.assertTrue(after.mail:RequestSend())
    after.mail:OnSent()
    test.assertEqual(1, #after.sent)
    test.assertEqual("Gus Reed", after.sent[1].to)
    test.assertEqual("Join us on Discord!", after.sent[1].body)
    test.assertEqual(addon.GuildMailSender.DONE, world.outbox[1].state)
end)

test.test("guild mail outbox: another character on the account can resume it", function()
    local _, world = newMail()
    sendOne(world)

    local addon, after = reload(world, { selfKey = "hammer smith-camelot" })
    after.mail:Open(true)
    test.assertEqual(addon.GuildMailSender.UNCONFIRMED, after.view.model.recipients[2].status)
    test.assertEqual("tool box-camelot", world.outbox[1].by)
end)

test.test("guild mail outbox: a mail in flight when the game closed is unconfirmed until settled", function()
    local _, world = newMail()
    sendOne(world)
    -- Gus Reed's mail was waiting for the game's answer.
    test.assertTrue(world.outbox[1].recipients[2].inFlight)

    local addon, after = reload(world)
    after.mail:Open(true)
    test.assertEqual(addon.GuildMailSender.UNCONFIRMED, after.view.model.recipients[2].status)
    test.assertEqual("Sent 1 · Failed 0, 1 unconfirmed · Postage spent: 30c", after.view.model.progressText)
    test.assertFalse(after.mail:RequestSend())
    test.assertEqual(0, #after.sent)

    -- Send makes it pending again, and Continue sends it.
    test.assertTrue(after.mail:Settle(2, true))
    test.assertEqual(addon.GuildMailSender.PENDING, world.outbox[1].recipients[2].status)
    test.assertTrue(after.mail:RequestSend())
    test.assertEqual("Gus Reed", after.sent[1].to)
end)

test.test("guild mail outbox: skipping an unconfirmed mail sends nothing", function()
    local _, world = newMail()
    sendOne(world)

    local addon, after = reload(world)
    after.mail:Open(true)
    test.assertFalse(after.mail:Settle(1, false))
    test.assertTrue(after.mail:Settle(2, false))
    test.assertEqual(addon.GuildMailSender.SKIPPED, world.outbox[1].recipients[2].status)
    test.assertFalse(after.mail:RequestSend())
    test.assertEqual(0, #after.sent)
end)

test.test("guild mail outbox: a cap pause survives a restart as a pause", function()
    local _, world = newMail()
    readyToSend(world)
    world.mail:RequestSend()
    world.mail:Confirm()
    world.mail:OnError("You have reached the in-game cap of unique mail recipients")
    test.assertTrue(world.outbox[1].capped)

    local addon, after = reload(world)
    after.mail:Open(true)
    test.assertEqual(addon.GuildMail.HINT_CAPPED, after.view.model.hint)
    test.assertEqual(addon.GuildMail.RESUME_TEXT, after.view.model.sendText)
    after.mail:RequestSend()
    test.assertEqual("Ann Bell", after.sent[1].to)
end)

test.test("guild mail outbox: finished and unusable entries aren't put back", function()
    local _, world = newMail()
    sendOne(world)
    world.mail:OnSent()
    table.insert(world.outbox, { state = "stopped", recipients = { { name = "Ann Bell" } } })
    table.insert(world.outbox, "broken")

    local _, after = reload(world)
    after.mail:Open(true)
    test.assertFalse(after.view.model.sending)
    test.assertEqual(nil, after.view.model.progressText)
end)

-- Guild Mail tab ----------------------------------------------------------------

-- A saved, stopped send to Ann Bell and Gus Reed: Ann's sent, Gus's was in
-- flight when the game closed.
local function savedEntry(subject, at)
    return {
        subject = subject, body = "Hi", by = "tool box-camelot", at = at, perMail = 30, state = "sending",
        recipients = {
            { key = "ann bell-camelot", name = "Ann Bell", rank = 2, subject = subject, body = "Hi", status = "sent" },
            { key = "gus reed-camelot", name = "Gus Reed", rank = 2, subject = subject, body = "Hi",
                status = "pending", inFlight = true },
        },
    }
end

test.test("guild mail tab: lists the draft, then the mails newest first with their progress", function()
    local addon, world = newMail({ outbox = { savedEntry("Rules", 1400), savedEntry("Launch night", 4000) } })
    world.mail:SetSubject("Raid night")
    world.outbox[1].state = "done"
    world.outbox[1].recipients[2].status = "failed"
    world.outbox[1].recipients[2].inFlight = nil

    local model = world.mail:OutboxModel()
    test.assertEqual("Raid night", model.draft.subject)
    test.assertEqual(2, #model.entries)
    test.assertEqual("Launch night", model.entries[1].subject)
    test.assertEqual(2, model.entries[1].position)
    test.assertEqual("Stopped", model.entries[1].stateText)
    test.assertEqual("Sent 1 of 2, 1 unconfirmed", model.entries[1].progressText)
    test.assertEqual("16 min ago", model.entries[1].whenText)
    test.assertEqual("Done", model.entries[2].stateText)
    test.assertEqual("1 h ago", model.entries[2].whenText)
    test.assertTrue(model.entries[2].canRemove)
    test.assertFalse(model.entries[1].canRemove)
    test.assertTrue(model.entries[1].canCancel)
    -- Resume needs a mailbox, and something left to send.
    test.assertFalse(model.entries[1].canResume)
    world.mail:OnMailboxOpened()
    test.assertFalse(world.mail:OutboxModel().entries[1].canResume)
    test.assertEqual(addon.GuildMailSender.UNCONFIRMED, world.mail:Model().recipients[2].status)
end)

test.test("guild mail tab: New asks before discarding a draft, then opens a blank mail", function()
    local _, world = newMail()
    world.mail:SetSubject("Raid night")

    test.assertTrue(world.mail:RequestNew())
    test.assertEqual("Discard the current draft?", world.mail:OutboxModel().actionText)
    world.mail:DismissAction()
    test.assertEqual("Raid night", world.mail.subject)

    world.mail:RequestNew()
    test.assertTrue(world.mail:ConfirmAction())
    test.assertEqual("", world.mail.subject)
    test.assertEqual("", world.saved.subject)
    test.assertTrue(world.view.shown)
    test.assertEqual(nil, world.mail:OutboxModel().draft)

    world.view.shown = false
    test.assertTrue(world.mail:RequestNew())
    test.assertTrue(world.view.shown)
end)

test.test("guild mail tab: a send paused at the limit can be set aside for a new one, then resumed", function()
    local addon, world = newMail()
    sendOne(world)
    world.mail:OnError("You have reached the in-game cap of unique mail recipients")

    -- Edit: the draft is editable again while the send waits.
    test.assertTrue(world.mail:EditDraft())
    test.assertTrue(world.mail:SetSubject("Raid night"))
    test.assertFalse(world.view.model.sending)
    world.mail:RequestSend()
    test.assertTrue(world.mail:Confirm())
    test.assertEqual(2, #world.outbox)
    test.assertEqual("Raid night", world.sent[3].subject)
    test.assertEqual("paused", world.outbox[1].state)

    -- One send at a time.
    local model = world.mail:OutboxModel()
    test.assertEqual("Paused at the mail limit", model.entries[2].stateText)
    test.assertFalse(model.entries[2].canResume)
    world.mail:OnSent()
    world.mail:OnSent()
    test.assertTrue(world.mail:OutboxModel().entries[2].canResume)

    test.assertTrue(world.mail:ResumeEntry(1))
    test.assertEqual("Gus Reed", world.sent[#world.sent].to)
    test.assertEqual("Launch night", world.sent[#world.sent].subject)
    world.mail:OnSent()
    test.assertEqual(addon.GuildMailSender.DONE, world.outbox[1].state)
    test.assertEqual(2, world.mail:entryCounts(world.outbox[1]).sent)
end)

test.test("guild mail tab: Cancel asks, then nothing more is sent; a finished mail can be removed", function()
    local addon, world = newMail()
    sendOne(world)
    -- Cancel waits while a mail is waiting for the game's answer, and a
    -- finished mail has nothing to cancel.
    test.assertFalse(world.mail:RequestCancelEntry(1))
    world.mail:OnSent()
    test.assertFalse(world.mail:RequestCancelEntry(1))
    test.assertEqual(2, #world.sent)

    -- A cancelled pending mail.
    local _, other = newMail()
    readyToSend(other)
    other.mail:RequestSend()
    other.mail:Confirm()
    other.mail:Stop()
    other.mail:OnSent()
    test.assertTrue(other.mail:RequestCancelEntry(1))
    test.assertEqual("Cancel this mail? 1 mail still waiting won't be sent.", other.mail.pendingAction.text)
    other.mail:ConfirmAction()
    test.assertEqual(addon.GuildMailSender.CANCELLED, other.outbox[1].recipients[2].status)
    test.assertFalse(other.mail:ResumeEntry(1))
    test.assertEqual("Cancelled", other.mail:OutboxModel().entries[1].stateText)
    test.assertEqual("Sent 1 of 2, 1 cancelled", other.mail:OutboxModel().entries[1].progressText)

    test.assertTrue(other.mail:RequestRemoveEntry(1))
    test.assertTrue(other.mail:ConfirmAction())
    test.assertEqual(0, #other.outbox)
end)

test.test("guild mail tab: a cancelled send never comes back after a reload", function()
    local _, world = newMail({ outbox = { savedEntry("Launch night", 4000) } })
    world.mail:RequestCancelEntry(1)
    world.mail:ConfirmAction()

    local _, after = reload(world)
    after.mail:Open(true)
    after.mail:RequestSend()
    test.assertEqual(0, #after.sent)
    test.assertFalse(after.view.model.sending)
end)

test.test("guild mail tab: View shows a saved mail read-only, and its unconfirmed mail can be settled", function()
    local addon, world = newMail({ outbox = { savedEntry("Rules", 1400), savedEntry("Launch night", 4000) } })
    world.mail:OnMailboxOpened()

    -- The newest came back in the sender; view the older one.
    test.assertTrue(world.mail:ViewEntry(1))
    local entry = world.view.model.entry
    test.assertEqual(1, entry.position)
    test.assertEqual("Rules", entry.subject)
    test.assertEqual("Ann Bell", entry.preview.to)
    test.assertEqual("Member", entry.recipients[1].rankName)
    test.assertEqual(addon.GuildMailSender.UNCONFIRMED, entry.recipients[2].status)
    test.assertTrue(entry.recipients[2].canSettle)

    test.assertTrue(world.mail:Settle(2, true))
    test.assertEqual("pending", world.outbox[1].recipients[2].status)
    test.assertEqual(nil, world.outbox[1].recipients[2].inFlight)
    test.assertTrue(world.view.model.entry.canResume)
    test.assertTrue(world.mail:ResumeEntry(1))
    test.assertEqual("Gus Reed", world.sent[1].to)
    test.assertEqual("Rules", world.sent[1].subject)

    world.mail:CloseEntry()
    test.assertEqual(nil, world.view.model.entry)
end)

-- Welcome mail page ---------------------------------------------------------

test.test("guild mail welcome: an officer edits the welcome mail on its own page and saves it", function()
    local addon, world = newMail()

    test.assertTrue(world.mail:OpenWelcome())
    test.assertTrue(world.view.shown)
    local welcome = world.view.model.welcome
    test.assertEqual("", welcome.subject)
    test.assertFalse(welcome.on)
    test.assertFalse(welcome.canSave)
    test.assertEqual(addon.GuildMail.HINT_NO_SUBJECT, welcome.hint)
    test.assertEqual(addon.GuildWelcome.TYPE_ASK_CONFIG, world.announced[1].t)

    world.mail:SetWelcomeSubject("Welcome, {name}!")
    world.mail:SetWelcomeBody("Hi {character}, join our Discord.")
    welcome = world.view.model.welcome
    test.assertTrue(welcome.canSave)
    test.assertFalse(welcome.saved)
    test.assertEqual("Welcome, Tool Box!", welcome.preview.subject)
    test.assertEqual("Hi Tool Box, join our Discord.", welcome.preview.body)
    -- Nothing is shared until it's saved.
    test.assertEqual(1, #world.announced)

    test.assertTrue(world.mail:SaveWelcome())
    welcome = world.view.model.welcome
    test.assertTrue(welcome.saved)
    test.assertFalse(welcome.canSave)
    test.assertEqual(addon.GuildMail.WELCOME_SAVED, welcome.hint)
    test.assertEqual(addon.GuildWelcome.TYPE_CONFIG, world.announced[2].t)
    test.assertEqual("Welcome, {name}!", world.mail.welcome:Subject())
end)

test.test("guild mail welcome: the switch starts off and changes at once", function()
    local _, world = newMail()
    world.mail:OpenWelcome()

    test.assertTrue(world.mail:SetWelcomeOn(true))
    test.assertTrue(world.view.model.welcome.on)
    test.assertTrue(world.mail.welcome:IsOn())
    world.mail:SetWelcomeOn(false)
    test.assertFalse(world.mail.welcome:IsOn())
end)

test.test("guild mail welcome: Back drops unsaved typing; a non-officer can't open it", function()
    local _, world = newMail()
    world.mail:OpenWelcome()
    world.mail:SetWelcomeSubject("Draft")
    world.mail:CloseWelcome()
    test.assertEqual(nil, world.view.model.welcome)
    world.mail:OpenWelcome()
    test.assertEqual("", world.view.model.welcome.subject)

    local _, member = newMail({ officer = false })
    test.assertFalse(member.mail:OpenWelcome())
    test.assertEqual(nil, (member.mail:SaveWelcome()))
end)

test.test("guild mail window: the Welcome mail page is drawn and its typing passed back", function()
    local _, world = newWindow()
    local model = {}
    local key, value
    for key, value in pairs(MODEL) do
        model[key] = value
    end
    model.welcome = {
        subject = "Welcome, {name}!", body = "Hi", on = true, canSave = true, hint = "Write a subject.",
        preview = { to = "Tool Box", subject = "Welcome, Tool Box!", body = "Hi" },
    }

    world.window:Render(model)
    test.assertTrue(world.window.welcomeFrame.shown)
    test.assertTrue(world.window.welcomeOn:GetChecked())
    test.assertEqual("Welcome, {name}!", world.window.welcomeSubject.text)
    test.assertEqual("As Tool Box would get it: Welcome, Tool Box!", world.window.welcomePreviewTo.text)
    test.assertEqual("Write a subject.", world.window.welcomeHint.text)

    world.window.welcomeSubject:SetText("Hello")
    world.window.welcomeSubject.scripts.OnTextChanged(world.window.welcomeSubject, true)
    world.window.welcomeSave.scripts.OnClick(world.window.welcomeSave)
    world.window.welcomeOn:SetChecked(false)
    world.window.welcomeOn.scripts.OnClick(world.window.welcomeOn)
    world.window.welcomeBack.scripts.OnClick(world.window.welcomeBack)
    local names = {}
    local index
    for index = 1, #world.calls do
        table.insert(names, world.calls[index].name)
    end
    test.assertEqual("welcomeSubject,welcomeSave,welcomeOn,welcomeBack", table.concat(names, ","))
    test.assertEqual("Hello", world.calls[1].args[1])
    test.assertFalse(world.calls[3].args[1])

    model.welcome = nil
    world.window:Render(model)
    test.assertFalse(world.window.welcomeFrame.shown)
end)

-- Welcome mails ---------------------------------------------------------------

local WELCOME_DAY = 24 * 60 * 60

-- Welcome mail on since 5000 with "Welcome, {name}!", and Dan New and
-- Eve New (Initiates) joined at 6000, due a day later, at the mailbox.
local function welcomesDue()
    local addon, world = newMail()
    world.time = 5000
    world.mail.welcome:Set({ subject = "Welcome, {name}!", body = "Hi {character}.", on = true })
    world.time = 6000
    world.partition:RecordCharacter("dan new-camelot", { name = "Dan New", rankIndex = 3 })
    world.partition:RecordCharacter("eve new-camelot", { name = "Eve New", rankIndex = 3 })
    world.mail.welcome:OnScan({ "dan new-camelot", "eve new-camelot" })
    world.time = 6000 + WELCOME_DAY
    world.mail:OnMailboxOpened()
    return addon, world
end

-- The welcome entry in the outbox.
local function welcomeEntry(world)
    local index
    for index = 1, #world.outbox do
        if world.outbox[index].kind == "welcome" then
            return world.outbox[index], index
        end
    end
    return nil
end

test.test("guild mail welcomes: due welcomes collect in a Welcome mails entry, counted on the tab", function()
    local addon, world = welcomesDue()

    local entry = welcomeEntry(world)
    test.assertEqual(2, #entry.recipients)
    test.assertEqual("Dan New", entry.recipients[1].name)
    -- Their rank as the roster has it, shown on the View page.
    test.assertEqual(3, entry.recipients[1].rank)
    world.mail:ViewEntry(1)
    test.assertEqual("Initiate", world.view.model.entry.recipients[1].rankName)
    world.mail:CloseEntry()
    test.assertEqual("Welcome, Dan New!", entry.recipients[1].subject)
    test.assertEqual("Guild Mail (2)", world.mail:TabTitle())
    local row = world.mail:OutboxModel().entries[1]
    test.assertEqual("Welcome mails: 2 waiting", row.subject)
    test.assertTrue(row.welcome)
    test.assertTrue(row.canResume)
    -- Collecting again adds nobody twice, and nothing goes without Send.
    world.mail:CollectWelcomes()
    test.assertEqual(2, #welcomeEntry(world).recipients)
    test.assertEqual(0, #world.sent)
    test.assertEqual(addon.GuildMailSender.STOPPED, entry.state)
end)

test.test("guild mail welcomes: nobody is due before the day is up", function()
    local _, world = newMail()
    world.time = 5000
    world.mail.welcome:Set({ subject = "Welcome!", on = true })
    world.time = 6000
    world.partition:RecordCharacter("dan new-camelot", { name = "Dan New", rankIndex = 3 })
    world.mail.welcome:OnScan({ "dan new-camelot" })
    world.time = 6000 + WELCOME_DAY - 1
    world.mail:OnMailboxOpened()

    test.assertEqual(nil, welcomeEntry(world))
    test.assertEqual("Guild Mail", world.mail:TabTitle())
end)

test.test("guild mail welcomes: Send sends each welcome filled in, records it, and tells the others", function()
    local addon, world = welcomesDue()
    -- The welcome changed since they were collected: Send uses it as it is now.
    world.mail.welcome:Set({ subject = "Hello, {name}!" })
    world.announced = {}

    test.assertTrue(world.mail:SendWelcomes())
    test.assertEqual("Dan New", world.sent[1].to)
    test.assertEqual("Hello, Dan New!", world.sent[1].subject)
    test.assertEqual("Hi Dan New.", world.sent[1].body)
    world.mail:OnSent()
    test.assertTrue(world.mail.welcome:IsWelcomed("dan new-camelot"))
    local message = world.announced[1]
    test.assertEqual(addon.GuildWelcome.TYPE_WELCOMED, message.t)
    test.assertEqual("dan new-camelot", message.c)
    test.assertEqual("dan new-camelot", message.m)
    test.assertEqual(6000 + WELCOME_DAY, message.a)

    world.mail:OnSent()
    test.assertEqual("Eve New", world.sent[2].to)
    test.assertEqual("Guild Mail", world.mail:TabTitle())
    test.assertEqual(addon.GuildMailSender.DONE, welcomeEntry(world).state)
    -- Welcomed newcomers aren't due again.
    world.mail:CollectWelcomes()
    test.assertEqual(2, #welcomeEntry(world).recipients)
end)

test.test("guild mail welcomes: another officer's welcome drops that player here; a non-officer's is ignored", function()
    local addon, world = welcomesDue()
    local message = { v = addon.GuildWelcome.PROTOCOL, t = addon.GuildWelcome.TYPE_WELCOMED,
        c = "dan new-camelot", m = "dan new-camelot", a = 7000 }

    test.assertFalse(world.mail.welcome:OnMessage(message, "Cog Wheel"))
    test.assertEqual("Guild Mail (2)", world.mail:TabTitle())
    test.assertTrue(world.mail.welcome:OnMessage(message, "Ann Bell"))
    test.assertEqual("Guild Mail (1)", world.mail:TabTitle())
    test.assertEqual(addon.GuildMailSender.SKIPPED, welcomeEntry(world).recipients[1].status)
    test.assertEqual(addon.GuildMail.WELCOMED_ELSEWHERE, welcomeEntry(world).recipients[1].reason)
    test.assertTrue(world.mail.welcome:IsWelcomed("dan new-camelot"))

    world.mail:SendWelcomes()
    test.assertEqual("Eve New", world.sent[1].to)
    test.assertEqual(1, #world.sent)
end)

test.test("guild mail welcomes: a welcome heard mid-send is skipped before it goes", function()
    local addon, world = welcomesDue()
    world.mail:SendWelcomes()

    world.mail.welcome:OnMessage({ v = addon.GuildWelcome.PROTOCOL, t = addon.GuildWelcome.TYPE_WELCOMED,
        c = "eve new-camelot", a = 7000 }, "Ann Bell")
    world.mail:OnSent()
    test.assertEqual(1, #world.sent)
    test.assertEqual(addon.GuildMailSender.DONE, welcomeEntry(world).state)
    test.assertEqual(addon.GuildMailSender.SKIPPED, welcomeEntry(world).recipients[2].status)
end)

test.test("guild mail welcomes: switched off, nothing new is due, and waiting welcomes stay", function()
    local _, world = welcomesDue()
    world.mail:SetWelcomeOn(false)
    world.partition:RecordCharacter("fay new-camelot", { name = "Fay New", rankIndex = 3 })
    world.mail.welcome:OnScan({ "fay new-camelot" })
    world.time = world.time + 2 * WELCOME_DAY

    world.mail:CollectWelcomes()
    test.assertEqual(2, #welcomeEntry(world).recipients)
    test.assertEqual("Guild Mail (2)", world.mail:TabTitle())
    test.assertTrue(world.mail:SendWelcomes())
end)

test.test("guild mail welcomes: waiting welcomes last across a restart, paused at the limit or not", function()
    local addon, world = welcomesDue()
    world.mail:SendWelcomes()
    world.mail:OnError("You have reached the in-game cap of unique mail recipients")

    local _, after = reload(world)
    after.time = world.time
    after.mail:Open(true)
    -- Welcomes wait in the tab; the window opens on the draft.
    test.assertFalse(after.view.model.sending)
    test.assertEqual("Guild Mail (2)", after.mail:TabTitle())
    test.assertEqual("Paused at the mail limit", after.mail:OutboxModel().entries[1].stateText)
    test.assertTrue(after.mail:SendWelcomes())
    test.assertEqual("Dan New", after.sent[1].to)
    test.assertEqual(addon.GuildMailSender.SENDING, welcomeEntry(world).state)
end)

test.test("guild mail welcomes: cancelling the waiting welcomes means they're not due again", function()
    local _, world = welcomesDue()
    local _, position = welcomeEntry(world)

    test.assertTrue(world.mail:RequestCancelEntry(position))
    test.assertTrue(world.mail:ConfirmAction())
    test.assertEqual("Guild Mail", world.mail:TabTitle())
    world.mail:CollectWelcomes()
    test.assertEqual(nil, world.mail:welcomeEntry())
    test.assertEqual(0, #world.sent)
end)

test.test("mailbox tab: the Welcome mails row has Edit, View and Send, and the title shows the count", function()
    local _, world = newTab()
    mailbox(world.environment)
    world.tab:Install(true)
    world.tab.handlers = nil
    world.tab.onEditWelcome = function()
        table.insert(world.calls, { name = "editWelcome", args = {} })
    end
    world.tab.onSendWelcomes = function()
        table.insert(world.calls, { name = "sendWelcomes", args = {} })
    end
    world.tab:Render({
        entries = { { position = 1, welcome = true, subject = "Welcome mails: 3 waiting", progressText = "Sent 0 of 3",
            state = "stopped", stateText = "Stopped", canResume = true } },
        canNew = true,
    })
    world.tab:SetTitle("Guild Mail (3)")

    local row = world.tab.rows[1]
    test.assertEqual("Edit", row.buttons[1].text)
    test.assertEqual("View", row.buttons[2].text)
    test.assertEqual("Send", row.buttons[3].text)
    test.assertEqual("Guild Mail (3)", world.tab.tab.text)
    row.buttons[1].scripts.OnClick(row.buttons[1])
    row.buttons[3].scripts.OnClick(row.buttons[3])
    -- The Welcome mail button beside New opens the same settings.
    test.assertEqual("Welcome mail", world.tab.welcome.text)
    world.tab.welcome.scripts.OnClick(world.tab.welcome)
    test.assertEqual("editWelcome", world.calls[1].name)
    test.assertEqual("sendWelcomes", world.calls[2].name)
    test.assertEqual("editWelcome", world.calls[3].name)
end)

test.test("guild mail: unticked people stay out of a send cut short by the mail limit and a reload", function()
    local addon, world = newMail()
    world.mail:Open(true)
    world.mail:SetRank(2, true)
    world.mail:SetRank(3, true)
    world.mail:SetMode("all")
    world.mail:SetSubject("Launch night")
    world.mail:OnMailboxOpened()
    -- Four Members and Initiates (Tool Box's own are always left out);
    -- leave Cog Wheel out.
    world.mail:SetRecipient("cog wheel-camelot", false)
    local wanted = {}
    local index
    for index = 1, #world.view.model.recipients do
        local row = world.view.model.recipients[index]
        if row.checked then
            table.insert(wanted, row.name)
        end
    end
    world.mail:RequestSend()
    world.mail:Confirm()
    world.mail:OnSent()
    world.mail:OnError("You have reached the in-game cap of unique mail recipients")

    local _, after = reload(world, { saved = world.saved })
    after.mail:Open(true)
    after.mail:RequestSend()
    while after.mail.sender:InFlight() ~= nil do
        after.mail:OnSent()
    end
    local everyone = { world.sent[1].to }
    for index = 1, #after.sent do
        table.insert(everyone, after.sent[index].to)
    end
    table.sort(everyone)
    table.sort(wanted)
    -- Each wanted recipient exactly once, and never Cog Wheel.
    test.assertEqual(table.concat(wanted, ","), table.concat(everyone, ","))
    test.assertEqual(addon.GuildMailSender.DONE, world.outbox[1].state)
    -- The draft still has Cog Wheel unticked.
    test.assertEqual("cog wheel-camelot", table.concat(after.saved.unticked, ","))
end)
