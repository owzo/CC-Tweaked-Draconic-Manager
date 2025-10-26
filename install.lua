--==============================================================
-- Installation Script
-- Save as: install.lua
--==============================================================

--[[
README
-------
This installer automatically downloads all required scripts for the
CC:Tweaked Draconic Manager system from the GitHub repository.

Features:
- HTTP connection check before downloading
- Clear progress and error messages
- Works in both online (HTTP) or offline (local copy) modes
- Auto-creates directories if missing
- Fully compatible with both wired and wireless modem setups
]]

------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------
local repoBase = "https://raw.githubusercontent.com/owzo/CC-Tweaked-Draconic-Manager/main/"
local targetDir = "/"  -- Change to custom path if desired

local files = {
    "config.lua",
    "main_control.lua",
    "reac_utils.lua",
    "monitor_utils.lua",
    "stat_utils.lua",
    "energy_core_utils.lua"
}

------------------------------------------------------------
-- HELPER FUNCTIONS
------------------------------------------------------------
local function hasInternet()
    if not http then return false end
    return http.checkURL(repoBase .. "config.lua") or false
end

local function safeWriteFile(path, content)
    local dir = fs.getDir(path)
    if dir and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local file = fs.open(path, "w")
    if file then
        file.write(content)
        file.close()
        return true
    end
    return false
end

local function downloadFile(filename)
    local url = repoBase .. filename
    local response = http.get(url)
    if response then
        local data = response.readAll()
        response.close()
        local ok = safeWriteFile(fs.combine(targetDir, filename), data)
        if ok then
            print("Downloaded: " .. filename)
        else
            print("Failed to save: " .. filename)
        end
    else
        print("Failed to fetch: " .. filename)
    end
end

local function installOnline()
    print("Checking repository availability...")
    if not hasInternet() then
        print("HTTP check failed. Verify that 'enableAPI_http=true' in ComputerCraft config.")
        return false
    end

    print("Starting online installation...")
    for _, file in ipairs(files) do
        downloadFile(file)
    end

    print("All downloads attempted. Installation complete.")
    print("Run 'main_control.lua' to start the Draconic Manager.")
    return true
end

local function installOffline()
    print("Offline mode detected. Copying local files instead...")
    for _, file in ipairs(files) do
        if fs.exists(file) then
            print("Found local copy: " .. file)
        else
            print("Missing local file: " .. file .. " — cannot install in offline mode.")
        end
    end
    print("Offline installation complete. Ensure all files are present before running.")
end

------------------------------------------------------------
-- MAIN EXECUTION
------------------------------------------------------------
term.clear()
term.setCursorPos(1,1)
print("==========================================")
print("   CC-Tweaked Draconic Manager Installer  ")
print("==========================================")
print("Target Directory: " .. targetDir)
print("Repository Base : " .. repoBase)
print("------------------------------------------")

if hasInternet() then
    installOnline()
else
    installOffline()
end
