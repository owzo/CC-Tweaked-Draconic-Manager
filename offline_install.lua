--==============================================================
-- Offline Installation Script
-- Save as: offline_install.lua
--==============================================================

--[[
README
-------
Offline installer for the CC:Tweaked Draconic Manager system.

Intended for servers or modpacks where the HTTP API is disabled.
Copies the required scripts from a floppy disk (or any mounted
drive) directly to the computer.

Features:
- Automatically detects the floppy disk mount point
- Validates each file before copying
- Creates missing directories automatically
- Generates a startup.lua file to auto-launch the controller
- Provides clear installation logs and status messages
]]

------------------------------------------------------------
-- FILE LIST
------------------------------------------------------------
local requiredFiles = {
    "config.lua",
    "main_control.lua",
    "energy_core_utils.lua",
    "reac_utils.lua",
    "monitor_utils.lua",
    "stat_utils.lua"
}

------------------------------------------------------------
-- HELPER FUNCTIONS
------------------------------------------------------------
local function findDiskMount()
    local mounts = peripheral.getNames()
    for _, name in ipairs(mounts) do
        if name:lower():find("disk") then
            return peripheral.getMountPath(name)
        end
    end
    -- Fallback if not detected via peripheral
    if fs.exists("disk") then return "disk" end
    return nil
end

local function copyFile(sourcePath, destPath)
    if not fs.exists(sourcePath) then
        print("Missing: " .. sourcePath)
        return false
    end

    local src = fs.open(sourcePath, "r")
    if not src then
        print("Failed to open: " .. sourcePath)
        return false
    end

    local data = src.readAll()
    src.close()

    local dir = fs.getDir(destPath)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local dest = fs.open(destPath, "w")
    if not dest then
        print("Failed to write: " .. destPath)
        return false
    end

    dest.write(data)
    dest.close()
    print("Installed: " .. destPath)
    return true
end

------------------------------------------------------------
-- MAIN INSTALLATION FUNCTION
------------------------------------------------------------
local function installFromDisk(diskPath)
    print("Installing from disk at: " .. diskPath)
    local successCount = 0
    for _, filename in ipairs(requiredFiles) do
        local src = fs.combine(diskPath, filename)
        local dest = fs.combine("/", filename)
        if copyFile(src, dest) then
            successCount = successCount + 1
        else
            print("Warning: Could not copy " .. filename)
        end
    end
    print(string.format("Installation complete. %d/%d files installed.", successCount, #requiredFiles))
end

------------------------------------------------------------
-- STARTUP SCRIPT CREATION
------------------------------------------------------------
local function createStartup()
    if fs.exists("startup.lua") then
        print("startup.lua already exists, skipping creation.")
        return
    end

    print("Creating startup.lua to auto-run main_control.lua...")
    local f = fs.open("startup.lua", "w")
    if not f then
        print("Failed to create startup.lua!")
        return
    end
    f.write('shell.run("main_control.lua")')
    f.close()
    print("startup.lua created successfully.")
end

------------------------------------------------------------
-- MAIN EXECUTION
------------------------------------------------------------
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("==========================================")
    print("  CC-Tweaked Draconic Manager (Offline)  ")
    print("==========================================")

    local diskPath = findDiskMount()
    if not diskPath then
        print("Error: No disk drive detected! Please insert a floppy disk.")
        return
    end

    installFromDisk(diskPath)
    createStartup()

    print("------------------------------------------")
    print("Installation complete.")
    print("Reboot your computer to start the manager.")
    print("------------------------------------------")
end

main()
