-- Fails when .pkgmeta externals drift from tools/libraries.txt.
-- Run from the repository root: lua5.1 tools/check-libraries.lua
package.path = "./?.lua;" .. package.path

local LibraryList = require("tools.library_list")

local entries, listError = LibraryList.Parse()
if entries == nil then
    io.stderr:write("Library list is invalid: ", tostring(listError), "\n")
    os.exit(1)
end

local pkgmeta, pkgmetaError = LibraryList.ParsePkgmeta()
if pkgmeta == nil then
    io.stderr:write(".pkgmeta is invalid: ", tostring(pkgmetaError), "\n")
    os.exit(1)
end

local problems = LibraryList.Compare(entries, pkgmeta)
if #problems > 0 then
    local index
    for index = 1, #problems do
        io.stderr:write(problems[index], "\n")
    end
    io.stderr:write(#problems, " library pin problem(s). Update .pkgmeta to match tools/libraries.txt.\n")
    os.exit(1)
end

io.write(#entries, " pinned libraries match .pkgmeta.\n")
