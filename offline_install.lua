-- Offline Installation Script
-- Save as: offline_install.lua

--[[
README

This script is designed for servers where HTTP API is disabled. 
Players can manually copy the required files to a ComputerCraft computer
via a floppy disk or other means.

Steps:
1. Place all required files on a floppy disk.
2. Insert the floppy disk into the target computer.
3. Run this script to copy the files and configure the system.
]]

local function copyFile(fromPath, toPath)
    if not fs.exists(fromPath) then
        error("Source file " .. fromPath .. " does not exist!")
    end

    local fileContent = fs.open(fromPath, "r").readAll()
    local file = fs.open(toPath, "w")
    file.write(fileContent)
    file.close()
end

local function installFiles()
    print("Installing files from floppy disk...")

    -- Define source and destination paths
    local files = {
        { source = "disk/config.lua", destination = "config.lua" },
        { source = "disk/main_control.lua", destination = "main_control.lua" },
        { source = "disk/energy_core_utils.lua", destination = "energy_core_utils.lua" },
        { source = "disk/reac_utils.lua", destination = "reac_utils.lua" },
        { source = "disk/monitor_utils.lua", destination = "monitor_utils.lua" },
        { source = "disk/stat_utils.lua", destination = "stat_utils.lua" }
    }

    -- Copy files
    for _, filePair in ipairs(files) do
        if fs.exists(filePair.source) then
            copyFile(filePair.source, filePair.destination)
            print("Installed: " .. filePair.destination)
        else
            print("WARNING: " .. filePair.source .. " not found on disk!")
        end
    end

    print("Installation complete!")
end

local function setupStartup()
    print("Setting up startup script...")

    -- Create a startup script to automatically run the program
    local startupFile = fs.open("startup.lua", "w")
    startupFile.write([[shell.run("main_control.lua")]])
    startupFile.close()

    print("Startup script configured!")
end

-- Run installation
local function main()
    installFiles()
    setupStartup()
    print("System is ready to use! Reboot to start the program.")
end

main()
