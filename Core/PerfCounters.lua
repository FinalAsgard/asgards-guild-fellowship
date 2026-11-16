local _, addon = ...

-- Counts of the add-on's expensive operations since login, for `/agf
-- perf`: how often each ran, so a change that saves work shows in game.
-- Pure: never touches the game.
local PerfCounters = {
    -- Each count, in the order the probe prints them.
    COUNTS = {
        { name = "rosterReads", label = "Whole-roster reads" },
        { name = "rosterMembers", label = "Roster member lookups (game calls)" },
        { name = "rosterUpdates", label = "Roster updates heard" },
        { name = "rosterRefreshes", label = "Roster-update refresh runs" },
        { name = "scansPlanned", label = "Incremental scans planned" },
        { name = "scansSkipped", label = "Incremental scans skipped (nothing changed)" },
        { name = "mapRedraws", label = "Map redraws (full)" },
        { name = "mapRedrawsMinimap", label = "Map redraws (minimap only)" },
        { name = "chatTags", label = "Chat tags worked out" },
        { name = "chatTagHits", label = "Chat tags reused" },
        { name = "greetChecks", label = "Guild chat greet checks run" },
        { name = "greetChecksSkipped", label = "Guild chat greet checks skipped (no prompt open)" },
    },
}
addon.PerfCounters = PerfCounters

local counts = {}

-- Adds `amount` (1 without it) to the count `name`.
function PerfCounters.Bump(name, amount)
    counts[name] = (counts[name] or 0) + (amount or 1)
end

-- The count `name`, 0 when it never ran.
function PerfCounters.Get(name)
    return counts[name] or 0
end

-- Starts every count again from 0.
function PerfCounters.Reset()
    counts = {}
end

-- What `/agf perf` prints. `usage` is the client's AddOnUsage: { memoryKB?,
-- cpuMs?, profiling, profilingHint?, recentMs?, sessionMs? }, nil where the
-- client can't report it; `profiling` is whether CPU profiling is on.
function PerfCounters.Lines(usage)
    local lines = {}
    if type(usage.memoryKB) == "number" then
        if usage.memoryKB >= 1024 then
            table.insert(lines, string.format("Memory: %.1f MB", usage.memoryKB / 1024))
        else
            table.insert(lines, string.format("Memory: %.0f KB", usage.memoryKB))
        end
    else
        table.insert(lines, "Memory: unavailable on this client")
    end
    if type(usage.recentMs) == "number" or type(usage.sessionMs) == "number" then
        table.insert(lines, string.format("CPU per frame (game's add-on profiler): %.3f ms recently, %.3f ms" ..
            " this session", usage.recentMs or 0, usage.sessionMs or 0))
    end
    if usage.profiling and type(usage.cpuMs) == "number" then
        table.insert(lines, string.format("CPU since profiling began: %.0f ms", usage.cpuMs))
    elseif usage.profiling then
        table.insert(lines, "CPU: unavailable on this client")
    else
        table.insert(lines, "CPU: profiling is off" ..
            (usage.profilingHint and ("; turn it on with " .. usage.profilingHint .. " and reload") or ""))
    end
    table.insert(lines, "Since login:")
    local index
    for index = 1, #PerfCounters.COUNTS do
        local count = PerfCounters.COUNTS[index]
        table.insert(lines, "  " .. count.label .. ": " .. PerfCounters.Get(count.name))
    end
    return lines
end
