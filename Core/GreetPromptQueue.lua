local _, addon = ...

-- The greet prompts waiting for the user, oldest first. There is at most one
-- per player: a newer prompt for the same player replaces the older one. A
-- prompt can wait a few seconds before it shows (so the greeting doesn't
-- arrive before the player's game has loaded), then disappears `lifetime`
-- seconds after it showed, so a greeting never arrives long after someone
-- did. While prompts are held (the
-- user is in combat) none are shown, but they keep their expiry times, so
-- releasing the hold shows only those still current. Pure: time is passed
-- in.
local GreetPromptQueue = {
    LIFETIME_SECONDS = 2 * 60,
}
addon.GreetPromptQueue = GreetPromptQueue

local Queue = {}
Queue.__index = Queue

function GreetPromptQueue.Create()
    return setmetatable({
        lifetime = GreetPromptQueue.LIFETIME_SECONDS,
        prompts = {},
        held = false,
    }, Queue)
end

local function indexOf(prompts, player)
    local index
    for index = 1, #prompts do
        if prompts[index].player == player then
            return index
        end
    end
    return nil
end

-- Adds `prompt` ({ category, player, key, ... }) raised at `now`, to show
-- `delay` seconds later (0 when nil). Returns the second at which it
-- expires.
function Queue:Add(prompt, now, delay)
    local existing = indexOf(self.prompts, prompt.player)
    if existing ~= nil then
        table.remove(self.prompts, existing)
    end
    prompt.raisedAt = now
    prompt.showAt = now + (delay or 0)
    prompt.expiresAt = prompt.showAt + self.lifetime
    table.insert(self.prompts, prompt)
    return prompt.expiresAt
end

-- Holds prompts back (true) or lets them show again (false).
function Queue:SetHeld(held)
    self.held = held == true
end

-- Drops prompts that have expired by `now`, and returns those due to show,
-- oldest first, or none while they're held.
function Queue:Visible(now)
    local index = 1
    while index <= #self.prompts do
        if self.prompts[index].expiresAt <= now then
            table.remove(self.prompts, index)
        else
            index = index + 1
        end
    end
    if self.held then
        return {}
    end
    local due = {}
    for index = 1, #self.prompts do
        if self.prompts[index].showAt <= now then
            table.insert(due, self.prompts[index])
        end
    end
    return due
end

-- The waiting prompt for `player`, or nil.
function Queue:Get(player)
    local index = indexOf(self.prompts, player)
    return index and self.prompts[index] or nil
end

-- Removes the prompt for `player` (greeted or closed). False when there was
-- none.
function Queue:Remove(player)
    local index = indexOf(self.prompts, player)
    if index == nil then
        return false
    end
    table.remove(self.prompts, index)
    return true
end

-- Removes every prompt in `category` (its prompts were turned off).
function Queue:RemoveCategory(category)
    local index = 1
    while index <= #self.prompts do
        if self.prompts[index].category == category then
            table.remove(self.prompts, index)
        else
            index = index + 1
        end
    end
end

-- Removes every prompt (Guild Greet was turned off).
function Queue:Clear()
    self.prompts = {}
end
