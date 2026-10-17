local test = require("tests.test_helper")
local FakeFrames = require("tests.fake_frames")
local fixtures = require("tests.client_fixtures")

local function load()
    return test.newAddon(
        "Core/NameNormalizer.lua",
        "Core/FellowshipStore.lua",
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

local function recipientsFor(ranks, selfKey)
    local addon, partition = setup()
    return addon.GuildMailAudience.Recipients(partition, { ranks = ranks, selfKey = selfKey })
end

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
        send = function(to, subject, body)
            table.insert(world.sent, { to = to, subject = subject, body = body })
            return true
        end,
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
    test.assertEqual("Send 2 mails?", model.confirmText)
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
    test.assertEqual("Sent 0 of 2", world.view.model.progressText)
    test.assertEqual(addon.GuildMail.HINT_SENDING, world.view.model.hint)
    test.assertEqual(addon.GuildMailSender.PENDING, world.view.model.recipients[1].status)

    world.mail:OnSent()
    test.assertEqual(2, #world.sent)
    test.assertEqual("Gus Reed", world.sent[2].to)
    test.assertEqual("Sent 1 of 2", world.view.model.progressText)

    world.mail:OnSent()
    test.assertEqual("Sent 2 of 2. Done.", world.view.model.progressText)
    test.assertEqual(addon.GuildMailSender.SENT, world.view.model.recipients[2].status)
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

test.test("guild mail: retyping the same text changes nothing", function()
    local _, world = newMail()
    readyToSend(world)

    test.assertFalse(world.mail:SetSubject("Launch night"))
    test.assertFalse(world.mail:SetRank(2, true))
end)

-- Window ----------------------------------------------------------------------

local function newWindow()
    local addon = test.newAddon("Adapters/GuildMailWindow.lua")
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
        onSubject = record("subject"),
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
    recipients = {
        { name = "Ann Bell", rank = 2, rankName = "Member" },
        { name = "Gus Reed", rank = 2, rankName = "Member", status = "failed", reason = "Mailbox full" },
    },
    countText = "2 mails",
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
    test.assertEqual("Recipients (2 mails)", world.window.listLabel.text)
    test.assertContains(world.window.listText.text, "Ann Bell")
    test.assertContains(world.window.listText.text, "Mailbox full")
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
