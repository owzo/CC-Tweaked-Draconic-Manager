--==============================================================
-- Installation Script
-- Save as: install.lua
--==============================================================

--[[
README
-------
Downloads the CC:Tweaked Draconic Manager from GitHub and creates a
startup.lua so the manager runs automatically after every reboot or
chunk reload.

Usage:  install            install / update from the main branch
        install <branch>   install from another branch or tag

Requires the HTTP API (enabled by default in CC:Tweaked). For servers
that disable it, use offline_install.lua instead.
]]

local args = {...}
local branch = args[1] or "main"
local repoBase = "https://raw.githubusercontent.com/owzo/CC-Tweaked-Draconic-Manager/"
    .. branch .. "/"

local files = {
    "main_control.lua",
    "reac_utils.lua",
    "monitor_utils.lua",
    "stat_utils.lua",
    "energy_core_utils.lua",
    "config.lua"
}
-- Never overwrite a player's tuned settings on update.
local preserve = {["config.lua"] = true}

local STARTUP = 'shell.run("main_control.lua")\n'
local ATTEMPTS = 3

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function fetch(url)
    for attempt = 1, ATTEMPTS do
        local response, err = http.get(url)
        if response then
            local code = response.getResponseCode and response.getResponseCode() or 200
            local body = response.readAll()
            response.close()
            if code == 200 and body and #body > 0 then
                return body
            end
            err = "HTTP " .. tostring(code)
        end
        if attempt < ATTEMPTS then
            sleep(attempt)
        else
            return nil, err
        end
    end
end

local function writeFile(path, content)
    local handle = fs.open(path, "w")
    if not handle then return false end
    handle.write(content)
    handle.close()
    return true
end

------------------------------------------------------------
-- MAIN
------------------------------------------------------------
term.clear()
term.setCursorPos(1, 1)
print("CC:Tweaked Draconic Manager installer")
print("Source: " .. repoBase)
print("")

if not http then
    printError("HTTP API is disabled on this server.")
    print("Use offline_install.lua from a floppy disk instead.")
    return
end

-- Download everything first so a failure leaves the old install intact.
local downloaded, failed = {}, {}
for _, name in ipairs(files) do
    if preserve[name] and fs.exists(name) then
        print("Keeping existing " .. name)
    else
        local body, err = fetch(repoBase .. name)
        if body then
            downloaded[name] = body
            print("Downloaded " .. name)
        else
            table.insert(failed, name .. " (" .. tostring(err) .. ")")
        end
    end
end

if #failed > 0 then
    printError("Download failed, nothing was changed:")
    for _, f in ipairs(failed) do printError("  " .. f) end
    print("Check that raw.githubusercontent.com is allowed in the server's CC:Tweaked http rules.")
    return
end

for name, body in pairs(downloaded) do
    if not writeFile(name, body) then
        printError("Could not write " .. name .. " (disk full?)")
        return
    end
end

if not fs.exists("startup.lua") then
    writeFile("startup.lua", STARTUP)
    print("Created startup.lua")
else
    print("startup.lua exists; make sure it runs main_control.lua")
end

print("")
print("Installed. Review config.lua, then run: main_control")
