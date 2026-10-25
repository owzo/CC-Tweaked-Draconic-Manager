--==============================================================
-- Offline Installation Script
-- Save as: offline_install.lua
--==============================================================

--[[
README
-------
Installs the CC:Tweaked Draconic Manager from a floppy disk, for servers
where the HTTP API is disabled.

1. Copy every .lua file from this repository onto a floppy disk
   (in single player you can paste them into
   saves/<world>/computercraft/disk/<id>/).
2. Put the disk in a disk drive next to the reactor computer.
3. Run:  disk/offline_install

Usage:  offline_install           auto-detect the disk
        offline_install <path>    install from a specific folder
]]

local args = {...}

local requiredFiles = {
    "main_control.lua",
    "reac_utils.lua",
    "monitor_utils.lua",
    "stat_utils.lua",
    "storage_utils.lua",
    "er_utils.lua",
    "mek_utils.lua",
    "persist.lua",
    "log_shipper.lua",
    "theme.lua",
    "alarms.lua",
    "totals.lua",
    "updater.lua",
    "drivers/draconic.lua",
    "drivers/extreme.lua",
    "drivers/mekanism.lua",
    "drivers/storage.lua",
    "config.lua"
}
local preserve = {["config.lua"] = true}
local STARTUP = 'shell.run("main_control.lua")\n'

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function hasAllFiles(dir)
    for _, name in ipairs(requiredFiles) do
        if not fs.exists(fs.combine(dir, name)) then
            return false
        end
    end
    return true
end

-- Finds a mounted disk that contains the program files.
local function findSource()
    if args[1] then
        return hasAllFiles(args[1]) and args[1] or nil
    end
    -- The folder this script was run from (e.g. "disk").
    local here = shell and fs.getDir(shell.getRunningProgram())
    if here and here ~= "" and hasAllFiles(here) then
        return here
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" and disk.hasData(name) then
            local mount = disk.getMountPath(name)
            if mount and hasAllFiles(mount) then
                return mount
            end
        end
    end
    return nil
end

------------------------------------------------------------
-- MAIN
------------------------------------------------------------
term.clear()
term.setCursorPos(1, 1)
print("CC:Tweaked Draconic Manager offline installer")
print("")

local source = findSource()
if not source then
    printError("No disk with all program files found.")
    print("The disk must contain:")
    for _, name in ipairs(requiredFiles) do print("  " .. name) end
    return
end
print("Installing from /" .. source)

for _, name in ipairs(requiredFiles) do
    local dest = "/" .. name
    if preserve[name] and fs.exists(dest) then
        print("Keeping existing " .. name)
    else
        if fs.exists(dest) then fs.delete(dest) end
        local dir = fs.getDir(dest)
        if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        fs.copy(fs.combine(source, name), dest)
        print("Installed " .. name)
    end
end

if not fs.exists("/startup.lua") then
    local handle = fs.open("/startup.lua", "w")
    handle.write(STARTUP)
    handle.close()
    print("Created startup.lua")
end

print("")
print("Done. Remove the disk (a disk startup file would run first),")
print("review config.lua, then run: main_control")
