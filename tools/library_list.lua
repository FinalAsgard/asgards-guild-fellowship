-- Reads tools/libraries.txt and the externals in .pkgmeta, and reports every
-- way they disagree. Shared by tools/check-libraries.lua (CI) and the specs.
-- Plain Lua 5.1; paths are relative to the repository root.
local LibraryList = {
    LIST_PATH = "tools/libraries.txt",
    PKGMETA_PATH = ".pkgmeta",
}

local COLUMNS = { "name", "major", "target", "load", "type", "url", "tag" }

local function trim(value)
    return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function split(line)
    local fields = {}
    local field
    for field in string.gmatch(line .. "|", "([^|]*)|") do
        table.insert(fields, trim(field))
    end
    return fields
end

local function endsWith(value, suffix)
    return suffix == "" or string.sub(value, -string.len(suffix)) == suffix
end

-- Returns nil when `entry` is well formed, or what is wrong with it.
local function entryProblem(entry)
    local index
    for index = 1, #COLUMNS do
        if entry[COLUMNS[index]] == "" then
            return "has an empty " .. COLUMNS[index]
        end
    end
    if string.match(entry.target, "^Libs/[^/]") == nil or string.find(entry.target, "..", 1, true) then
        return "target must be a folder under Libs/"
    end
    if string.find(entry.load, "..", 1, true) or string.sub(entry.load, 1, 1) == "/" then
        return "load must be a file inside its target"
    end
    if entry.type == "svn" then
        local marker = "/tags/" .. entry.tag
        if not endsWith(entry.url, marker) and string.find(entry.url, marker .. "/", 1, true) == nil then
            return "svn url must point at its pinned tag folder (" .. marker .. ")"
        end
    elseif entry.type ~= "git" then
        return "type must be git or svn"
    end
    return nil
end

-- Returns the list's entries in order, or nil and an error.
function LibraryList.Parse(path)
    path = path or LibraryList.LIST_PATH
    local handle, openError = io.open(path, "r")
    if handle == nil then
        return nil, openError
    end

    local entries, seenTargets, seenMajors = {}, {}, {}
    local lineNumber = 0
    local line
    for line in handle:lines() do
        lineNumber = lineNumber + 1
        line = trim(line)
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local fields = split(line)
            if #fields ~= #COLUMNS then
                handle:close()
                return nil, path .. ":" .. lineNumber .. ": expected " .. #COLUMNS .. " columns, got " .. #fields
            end
            local entry = {}
            local index
            for index = 1, #COLUMNS do
                entry[COLUMNS[index]] = fields[index]
            end
            local problem = entryProblem(entry)
            if problem == nil and seenTargets[entry.target] then
                problem = "repeats target " .. entry.target
            elseif problem == nil and seenMajors[entry.major] then
                problem = "repeats major " .. entry.major
            end
            if problem ~= nil then
                handle:close()
                return nil, path .. ":" .. lineNumber .. ": " .. entry.name .. " " .. problem
            end
            seenTargets[entry.target] = true
            seenMajors[entry.major] = true
            table.insert(entries, entry)
        end
    end
    handle:close()
    return entries
end

-- Reads the subset of .pkgmeta this project writes: `package-as`, the
-- `externals` map (path -> url, tag, type), and the `ignore` list.
function LibraryList.ParsePkgmeta(path)
    path = path or LibraryList.PKGMETA_PATH
    local handle, openError = io.open(path, "r")
    if handle == nil then
        return nil, openError
    end

    local pkgmeta = { externals = {}, externalOrder = {}, ignore = {} }
    local section, current
    local line
    for line in handle:lines() do
        local content = string.gsub(line, "%s+$", "")
        if content ~= "" and string.match(content, "^%s*#") == nil then
            local topKey, topValue = string.match(content, "^([%w%-]+):%s*(.-)$")
            if topKey ~= nil then
                section = topKey
                current = nil
                if topKey == "package-as" then
                    pkgmeta.packageAs = topValue
                end
            elseif section == "externals" then
                local externalPath = string.match(content, "^  ([^%s:][^:]*):$")
                local field, value = string.match(content, "^    ([%w%-]+):%s*(.-)$")
                if externalPath ~= nil then
                    current = { path = externalPath }
                    pkgmeta.externals[externalPath] = current
                    table.insert(pkgmeta.externalOrder, externalPath)
                elseif field ~= nil and current ~= nil then
                    current[field] = value
                else
                    handle:close()
                    return nil, path .. ": unreadable externals line: " .. content
                end
            elseif section == "ignore" then
                local item = string.match(content, "^  %- (.+)$")
                if item ~= nil then
                    table.insert(pkgmeta.ignore, item)
                end
            end
        end
    end
    handle:close()
    return pkgmeta
end

-- Every difference between the list and the .pkgmeta externals.
function LibraryList.Compare(entries, pkgmeta)
    local problems = {}
    local listed = {}
    local index
    for index = 1, #entries do
        local entry = entries[index]
        listed[entry.target] = true
        local external = pkgmeta.externals[entry.target]
        if external == nil then
            table.insert(problems, entry.target .. " is pinned in the list but missing from .pkgmeta")
        else
            if external.url ~= entry.url then
                table.insert(problems, entry.target .. " url is " .. tostring(external.url) ..
                    " in .pkgmeta but " .. entry.url .. " in the list")
            end
            local externalType = external.type or "git"
            if externalType ~= entry.type then
                table.insert(problems, entry.target .. " type is " .. externalType ..
                    " in .pkgmeta but " .. entry.type .. " in the list")
            end
            -- An svn pin lives in its url; a git pin is its tag.
            local expectedTag = entry.type == "git" and entry.tag or nil
            if external.tag ~= expectedTag then
                table.insert(problems, entry.target .. " tag is " .. tostring(external.tag) ..
                    " in .pkgmeta but should be " .. tostring(expectedTag))
            end
        end
    end
    for index = 1, #pkgmeta.externalOrder do
        local externalPath = pkgmeta.externalOrder[index]
        if not listed[externalPath] then
            table.insert(problems, externalPath .. " is in .pkgmeta but not in the library list")
        end
    end
    return problems
end

-- The manifest lines that load the libraries, in list order.
function LibraryList.ManifestLines(entries)
    local lines = {}
    local index
    for index = 1, #entries do
        table.insert(lines, entries[index].target .. "/" .. entries[index].load)
    end
    return lines
end

return LibraryList
