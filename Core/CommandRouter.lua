local _, addon = ...

local CommandRouter = {}
addon.CommandRouter = CommandRouter

local Router = {}
Router.__index = Router

local function normalizeInput(input)
    if type(input) ~= "string" then
        return "", ""
    end

    local command, arguments = input:match("^%s*(%S*)%s*(.-)%s*$")
    return string.lower(command or ""), arguments or ""
end

function CommandRouter.Create(output)
    return setmetatable({
        commands = {},
        commandOrder = {},
        defaultCommand = "help",
        chatPrefix = addon.Identity.chatPrefix,
        output = type(output) == "function" and output or function() end,
        slashCommand = addon.Identity.slashCommand,
    }, Router)
end

function Router:Register(command, description, handler)
    if type(command) ~= "string" or command == "" or type(handler) ~= "function" then
        return false
    end

    command = string.lower(command)
    if self.commands[command] == nil then
        table.insert(self.commandOrder, command)
    end

    self.commands[command] = {
        description = description or "",
        handler = handler,
    }
    return true
end

-- Makes a registered command run when the slash command has no arguments.
function Router:SetDefault(command)
    if type(command) ~= "string" or self.commands[string.lower(command)] == nil then
        return false
    end

    self.defaultCommand = string.lower(command)
    return true
end

function Router:PrintHelp()
    local entries = {}
    local index

    for index = 1, #self.commandOrder do
        local command = self.commandOrder[index]
        local description = self.commands[command].description
        table.insert(entries, self.slashCommand .. " " .. command .. " - " .. description)
    end

    self.output(self.chatPrefix .. " Commands: " .. table.concat(entries, "; "))
end

function Router:Execute(input)
    local command, arguments = normalizeInput(input)
    if command == "" then
        command = self.defaultCommand
    end

    local route = self.commands[command]
    if route == nil then
        self.output(self.chatPrefix .. " Unknown command '" .. command ..
            "'. Use " .. self.slashCommand .. " help.")
        return false
    end

    route.handler(arguments)
    return true
end
