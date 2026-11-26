local test = require("tests.test_helper")

-- An editor over a real GreetingLibrary on saved state `state`, with the
-- switches, minutes and greet prompts in `world`.
local function newEditor(state, world)
    local addon = test.newAddon("Core/GreetingLibrary.lua", "Core/GreetingsEditor.lua")
    world = world or {}
    world.off = world.off or {}
    local library = addon.GreetingLibrary.Create(state)
    local editor = addon.GreetingsEditor.Create({
        library = function()
            if world.unavailable then
                return nil
            end
            return library
        end,
        enabled = function(category)
            return not world.off[category]
        end,
        minutes = function()
            return world.minutes
        end,
        promptsOn = function()
            return world.promptsOn ~= false
        end,
        names = function()
            return world.names
        end,
        now = function()
            return world.now or 0
        end,
    })
    return editor, addon, world
end

local function dots(view)
    local result = {}
    local index
    for index = 1, #view.categories do
        result[view.categories[index].id] = view.categories[index].dot
    end
    return result
end

test.test("greetings editor: Join is selected first, and each category shows its greetings and switch", function()
    local editor = newEditor({ greetings = { join = { "Welcome, {name}!" }, login = { "Hi", "Hey {name}" } } })

    local view = editor:View()
    test.assertEqual("join", view.category)
    test.assertEqual("Someone joins the guild.", view.description)
    test.assertEqual("greetCategory:join", view.switchId)
    test.assertEqual("Prompt me", view.switchLabel)
    test.assertTrue(view.enabled)
    test.assertEqual(nil, view.offNote)
    test.assertEqual(1, #view.rows)
    test.assertEqual("Welcome, {name}!", view.rows[1].text)

    test.assertTrue(editor:Select("login"))
    view = editor:View()
    test.assertEqual("login", editor:Selected())
    test.assertEqual("greetCategory:login", view.switchId)
    test.assertEqual(2, #view.rows)
    test.assertEqual(2, view.rows[2].index)
    test.assertEqual("Hey {name}", view.rows[2].text)

    -- An unknown category changes nothing.
    test.assertFalse(editor:Select("nope"))
    test.assertEqual("login", editor:Selected())
end)

test.test("greetings editor: the categories come in the library's order", function()
    local editor = newEditor({})

    local view = editor:View()
    test.assertEqual(4, #view.categories)
    test.assertEqual("join", view.categories[1].id)
    test.assertEqual("Login", view.categories[2].label)
    test.assertEqual("Welcome back", view.categories[3].label)
    test.assertEqual("Long absence", view.categories[4].label)
end)

test.test("greetings editor: Welcome back's line names the current minutes", function()
    local editor, _, world = newEditor({}, { minutes = 15 })
    editor:Select("welcomeBack")

    test.assertEqual("Someone you saw log off comes back after more than 15 minutes away.",
        editor:View().description)
    world.minutes = 1
    test.assertEqual("Someone you saw log off comes back after more than 1 minute away.", editor:View().description)
    -- Unknown minutes: the plain line.
    world.minutes = nil
    test.assertEqual("Someone you saw log off comes back after a break.", editor:View().description)
end)

test.test("greetings editor: a grey dot marks a category that's switched off or empty", function()
    local editor, _, world = newEditor({ greetings = { join = { "Hi" }, login = {}, welcomeBack = { "WB" } } })
    world.off.welcomeBack = true

    local shown = dots(editor:View())
    test.assertFalse(shown.join)
    test.assertTrue(shown.login)
    test.assertTrue(shown.welcomeBack)
    -- Long absence gets its starters on first use, and is on.
    test.assertFalse(shown.longAbsence)

    world.off.welcomeBack = false
    test.assertFalse(dots(editor:View()).welcomeBack)
end)

test.test("greetings editor: a switched-off category keeps its greetings under a short note", function()
    local editor, addon, world = newEditor({ greetings = { login = { "Hi", "Hey" } } })
    editor:Select("login")
    world.off.login = true

    local view = editor:View()
    test.assertFalse(view.enabled)
    test.assertEqual(addon.GreetingsEditor.OFF_NOTE, view.offNote)
    test.assertEqual(2, #view.rows)
end)

test.test("greetings editor: the page is dimmed while greet prompts are off", function()
    local editor, _, world = newEditor({})

    test.assertFalse(editor:View().dimmed)
    world.promptsOn = false
    test.assertTrue(editor:View().dimmed)
end)

test.test("greetings editor: each view reloads what's saved, and no saved data shows no greetings", function()
    local state = { greetings = { join = { "One" } } }
    local editor, _, world = newEditor(state)

    test.assertEqual(1, #editor:View().rows)
    -- Changed elsewhere (the old window's editor): the next view has it.
    table.insert(state.greetings.join, "Two")
    test.assertEqual("Two", editor:View().rows[2].text)

    world.unavailable = true
    local view = editor:View()
    test.assertEqual(0, #view.rows)
    test.assertTrue(dots(view).join)
end)

test.test("greetings editor: ✎ opens a greeting with its text; Save is greyed out until it's changed", function()
    local state = { greetings = { login = { "Hi", "Hey {name}" } } }
    local editor = newEditor(state)
    editor:Select("login")

    test.assertFalse(editor:StartEdit(3))
    test.assertTrue(editor:StartEdit(2))
    local view = editor:View()
    test.assertEqual(2, view.open)
    test.assertEqual("Hey {name}", view.draft)
    test.assertEqual("Save", view.saveLabel)
    test.assertFalse(view.saveEnabled)
    -- Only spaces changed: still nothing to save.
    editor:SetDraft("  Hey {name} ")
    test.assertFalse(editor:View().saveEnabled)
    test.assertFalse(editor:Save())
    editor:SetDraft("")
    test.assertFalse(editor:View().saveEnabled)

    editor:SetDraft("Hey there, {name}!")
    test.assertTrue(editor:View().saveEnabled)
    test.assertTrue(editor:Save())
    test.assertEqual("Hey there, {name}!", state.greetings.login[2])
    test.assertEqual(nil, editor:View().open)
end)

test.test("greetings editor: + Add a greeting opens an empty box, and Add puts it at the bottom", function()
    local state = { greetings = { join = { "Welcome!" } } }
    local editor, addon = newEditor(state)

    editor:StartAdd()
    local view = editor:View()
    test.assertEqual(addon.GreetingsEditor.NEW, view.open)
    test.assertEqual("", view.draft)
    test.assertEqual("Add", view.saveLabel)
    test.assertFalse(view.saveEnabled)

    editor:SetDraft("Glad you're here,\n{name}!")
    test.assertTrue(editor:Save())
    test.assertEqual("Glad you're here, {name}!", state.greetings.join[2])
    test.assertEqual("Glad you're here, {name}!", editor:View().rows[2].text)
end)

test.test("greetings editor: only one greeting is open, and Cancel drops the draft", function()
    local state = { greetings = { login = { "One", "Two" } } }
    local editor = newEditor(state)
    editor:Select("login")

    editor:StartEdit(1)
    editor:SetDraft("Changed")
    editor:StartEdit(2)
    local view = editor:View()
    test.assertEqual(2, view.open)
    test.assertEqual("Two", view.draft)
    editor:StartAdd()
    test.assertEqual("", editor:View().draft)
    editor:Cancel()
    test.assertEqual(nil, editor:View().open)
    test.assertEqual("One", state.greetings.login[1])
end)

test.test("greetings editor: switching category drops the draft quietly", function()
    local state = { greetings = { login = { "One" } } }
    local editor = newEditor(state)
    editor:Select("login")
    editor:StartEdit(1)
    editor:SetDraft("Not saved")

    -- The same category again keeps it.
    editor:Select("login")
    test.assertEqual("Not saved", editor:View().draft)
    editor:Select("join")
    test.assertEqual(nil, editor:View().open)
    test.assertEqual("One", state.greetings.login[1])
end)

test.test("greetings editor: a refused save keeps the box open with the reason, until it's typed in", function()
    local state = { greetings = { login = { "One" } } }
    local editor, _, world = newEditor(state)
    editor:Select("login")

    editor:StartAdd()
    editor:SetDraft(string.rep("a", 256))
    test.assertFalse(editor:Save())
    local view = editor:View()
    test.assertContains(view.error, "Can't save: it's longer than one guild chat message")
    test.assertEqual(string.rep("a", 256), view.draft)
    editor:SetDraft("Short")
    test.assertEqual(nil, editor:View().error)

    -- Gone elsewhere while open.
    editor:StartEdit(1)
    editor:SetDraft("Edited")
    state.greetings.login = {}
    test.assertFalse(editor:Save())
    test.assertEqual("Can't save: that greeting is gone.", editor:View().error)
    editor:ClearError()
    test.assertEqual(nil, editor:View().error)

    world.unavailable = true
    editor:StartAdd()
    editor:SetDraft("Hi")
    test.assertFalse(editor:Save())
    test.assertEqual("Can't save: saved data is unavailable.", editor:View().error)
end)

test.test("greetings editor: a placeholder goes in at the cursor, never inside a letter", function()
    local editor, addon = newEditor({ greetings = { login = { "Hi !" } } })
    editor:Select("login")

    -- Nothing open: nothing to insert into.
    test.assertEqual(nil, editor:Insert("{name}", 0))
    editor:StartEdit(1)
    local draft, cursor = editor:Insert("{name}", 3)
    test.assertEqual("Hi {name}!", draft)
    test.assertEqual(9, cursor)
    test.assertEqual("Hi {name}!", editor:View().draft)
    test.assertTrue(editor:View().saveEnabled)
    -- No cursor, or one past the end: at the end.
    test.assertEqual("Hi {name}!{main}", (editor:Insert("{main}", nil)))
    test.assertEqual("Hi {name}!{main}{character}", (editor:Insert("{character}", 99)))
    test.assertEqual("{main}Hi {name}!{main}{character}", (editor:Insert("{main}", 0)))

    -- A cursor inside é (two bytes) moves to its start.
    editor:SetDraft("é")
    test.assertEqual("{name}é", (editor:Insert("{name}", 1)))
    -- Past one chat message: refused, the draft kept.
    editor:SetDraft(string.rep("a", addon.GreetingLibrary.MAX_LENGTH - 3))
    test.assertEqual(nil, editor:Insert("{name}", 0))
    test.assertEqual(addon.GreetingLibrary.MAX_LENGTH - 3, #editor:View().draft)
end)

test.test("greetings editor: the preview fills the draft with the user's own names, in any case", function()
    local editor, _, world = newEditor({ greetings = { login = { "Hi" } } })
    world.names = { name = "Rip", main = "Bishop", character = "Ripley" }
    editor:Select("login")

    test.assertEqual(nil, editor:View().preview)
    editor:StartEdit(1)
    editor:SetDraft("Hey {NAME}, on {character}? ({Main}) {other}")
    test.assertEqual("Hey Rip, on Ripley? (Bishop) {other}", editor:View().preview)
    -- An empty draft has no preview.
    editor:SetDraft("   ")
    test.assertEqual(nil, editor:View().preview)
    editor:Cancel()
    test.assertEqual(nil, editor:View().preview)
end)

test.test("greetings editor: 🗑 arms a red Delete?, and a second click within 5 seconds deletes", function()
    local state = { greetings = { login = { "One", "Two", "Three" } } }
    local editor, addon, world = newEditor(state, { now = 100 })
    editor:Select("login")

    test.assertEqual("armed", editor:Delete(2))
    local view = editor:View()
    test.assertEqual(nil, view.rows[1].confirm)
    test.assertEqual(addon.GreetingsEditor.DELETE, view.rows[2].confirm)
    test.assertEqual("Delete?", view.rows[2].confirm)
    -- Nothing is deleted on the first click.
    test.assertEqual(3, #state.greetings.login)

    world.now = 104
    test.assertEqual("deleted", editor:Delete(2))
    test.assertEqual("One,Three", table.concat(state.greetings.login, ","))
    test.assertEqual(nil, editor:View().rows[2].confirm)
end)

test.test("greetings editor: Delete? expires after 5 seconds, and moves with the last click", function()
    local state = { greetings = { login = { "One", "Two" } } }
    local editor, _, world = newEditor(state, { now = 100 })
    editor:Select("login")

    editor:Delete(1)
    world.now = 105
    test.assertEqual(nil, editor:View().rows[1].confirm)
    -- After it expired, a click arms it again rather than deleting.
    test.assertEqual("armed", editor:Delete(1))
    test.assertEqual(2, #state.greetings.login)

    -- Another row's 🗑 moves it there.
    test.assertEqual("armed", editor:Delete(2))
    test.assertEqual(nil, editor:View().rows[1].confirm)
    test.assertEqual("Delete?", editor:View().rows[2].confirm)
    test.assertEqual("armed", editor:Delete(1))
    test.assertEqual(2, #state.greetings.login)

    -- Another category drops it.
    editor:Select("join")
    editor:Select("login")
    test.assertEqual(nil, editor:View().rows[1].confirm)
end)

test.test("greetings editor: a Delete? whose greeting changed elsewhere doesn't delete", function()
    local state = { greetings = { login = { "One", "Two" } } }
    local editor = newEditor(state, { now = 100 })
    editor:Select("login")

    editor:Delete(1)
    table.remove(state.greetings.login, 1)
    test.assertEqual(nil, editor:View().rows[1].confirm)
    test.assertEqual("armed", editor:Delete(1))
    test.assertEqual("Two", state.greetings.login[1])

    local ok, reason = editor:Delete(5)
    test.assertEqual(nil, ok)
    test.assertEqual("that greeting is gone", reason)
end)

test.test("greetings editor: the last Join, Login or Welcome back greeting reads Delete? (last one)", function()
    local editor, addon = newEditor({ greetings = { join = { "Hi" }, login = { "Hi" }, welcomeBack = { "WB" } } })

    local id
    for _, id in ipairs({ "join", "login", "welcomeBack" }) do
        editor:Select(id)
        editor:Delete(1)
        test.assertEqual(addon.GreetingsEditor.DELETE_LAST, editor:View().rows[1].confirm)
        test.assertEqual("Delete? (last one)", editor:View().rows[1].confirm)
    end
end)

test.test("greetings editor: deleting keeps the open box on its greeting, or closes it with it", function()
    local state = { greetings = { login = { "One", "Two", "Three" } } }
    local editor = newEditor(state)
    editor:Select("login")

    editor:StartEdit(3)
    editor:SetDraft("Three, changed")
    editor:Delete(1)
    editor:Delete(1)
    local view = editor:View()
    test.assertEqual(2, view.open)
    test.assertEqual("Three, changed", view.draft)
    test.assertTrue(editor:Save())
    test.assertEqual("Two,Three, changed", table.concat(state.greetings.login, ","))

    editor:StartEdit(1)
    editor:Delete(1)
    editor:Delete(1)
    test.assertEqual(nil, editor:View().open)
end)

test.test("greetings editor: without saved data a Delete? deletes nothing and says why", function()
    local state = { greetings = { login = { "One" } } }
    local editor, _, world = newEditor(state)
    editor:Select("login")

    editor:Delete(1)
    world.unavailable = true
    local ok, reason = editor:Delete(1)
    test.assertEqual(nil, ok)
    test.assertEqual("that greeting is gone", reason)
    world.unavailable = false
    test.assertEqual("One", state.greetings.login[1])
end)

test.test("greetings editor: an empty category says it won't prompt until a greeting is added", function()
    local editor = newEditor({ greetings = { join = {}, login = {}, welcomeBack = {} } })

    test.assertEqual("No Join greetings yet. You won't get join prompts until you add one.", editor:View().empty)
    editor:Select("login")
    test.assertEqual("No Login greetings yet. You won't get login prompts until you add one.", editor:View().empty)
    editor:Select("welcomeBack")
    test.assertEqual("No Welcome back greetings yet. You won't get welcome back prompts until you add one.",
        editor:View().empty)
    -- + Add a greeting works from there.
    editor:StartAdd()
    editor:SetDraft("WB {name}!")
    test.assertTrue(editor:Save())
    test.assertEqual(nil, editor:View().empty)
end)
