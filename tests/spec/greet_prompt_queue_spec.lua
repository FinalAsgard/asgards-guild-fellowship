local test = require("tests.test_helper")

local START = 1790000000

local function newQueue()
    return test.newAddon("Core/GreetPromptQueue.lua").GreetPromptQueue.Create()
end

local function players(prompts)
    local result = {}
    local index
    for index = 1, #prompts do
        table.insert(result, tostring(prompts[index].player))
    end
    return table.concat(result, ",")
end

test.test("prompt queue: prompts are shown oldest first, one per player", function()
    local queue = newQueue()

    queue:Add({ player = 1, category = "login" }, START)
    queue:Add({ player = 2, category = "login" }, START + 5)
    queue:Add({ player = 1, category = "welcomeBack" }, START + 10)

    local visible = queue:Visible(START + 10)
    test.assertEqual("2,1", players(visible))
    test.assertEqual("welcomeBack", visible[2].category)
end)

test.test("prompt queue: a prompt disappears exactly 2 minutes after it was raised", function()
    local queue = newQueue()

    test.assertEqual(START + 120, queue:Add({ player = 1 }, START))

    test.assertEqual("1", players(queue:Visible(START + 119)))
    test.assertEqual("", players(queue:Visible(START + 120)))
    test.assertEqual(nil, queue:Get(1))
end)

test.test("prompt queue: greeting or closing removes the prompt, and clearing removes all", function()
    local queue = newQueue()
    queue:Add({ player = 1 }, START)
    queue:Add({ player = 2 }, START)
    queue:Add({ player = 3 }, START)

    test.assertTrue(queue:Remove(2))
    test.assertFalse(queue:Remove(2))
    test.assertEqual("1,3", players(queue:Visible(START)))

    queue:Clear()
    test.assertEqual("", players(queue:Visible(START)))
end)

test.test("prompt queue: held prompts are hidden, then shown in arrival order when released", function()
    local queue = newQueue()
    queue:SetHeld(true)
    queue:Add({ player = 1 }, START)
    queue:Add({ player = 2 }, START + 10)

    test.assertEqual("", players(queue:Visible(START + 20)))

    queue:SetHeld(false)
    test.assertEqual("1,2", players(queue:Visible(START + 30)))
end)

test.test("prompt queue: a prompt that expires while held never appears", function()
    local queue = newQueue()
    queue:SetHeld(true)
    queue:Add({ player = 1 }, START)
    queue:Add({ player = 2 }, START + 60)

    queue:SetHeld(false)
    test.assertEqual("2", players(queue:Visible(START + 150)))
end)
