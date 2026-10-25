--==============================================================
-- IN-GAME UPDATER
-- Save as: updater.lua
--==============================================================

--[[
README
-------
Checks GitHub for a newer version and installs it from the monitor.

  updater.check(repoBase)   -> latest version string, or nil + error
  updater.newer(a, b)       -> true when version a is newer than b
  updater.install(repoBase) -> runs the official install.lua (which keeps
                               config.lua and only writes files once every
                               download succeeded), or nil + error

The caller puts reactors in their fail-safe state and reboots after a
successful install so startup.lua starts the new version.
]]

local updater = {}

local INSTALLER_PATH = "/.update_install.lua"

local function fetch(url)
    if not http then return nil, "HTTP API disabled on this server" end
    local response, err = http.get(url)
    if not response then return nil, tostring(err) end
    local body = response.readAll()
    response.close()
    if not body or #body == 0 then return nil, "empty response" end
    return body
end

function updater.check(repoBase)
    local body, err = fetch(repoBase .. "main_control.lua")
    if not body then return nil, err end
    local version = body:match('local%s+VERSION%s*=%s*"([^"]+)"')
    if not version then return nil, "version not found in main_control.lua" end
    return version
end

-- Compares dotted numeric versions ("4.10" > "4.9").
function updater.newer(a, b)
    local pa, pb = {}, {}
    for n in tostring(a):gmatch("%d+") do table.insert(pa, tonumber(n)) end
    for n in tostring(b):gmatch("%d+") do table.insert(pb, tonumber(n)) end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

function updater.install(repoBase)
    local body, err = fetch(repoBase .. "install.lua")
    if not body then return nil, err end
    local handle = fs.open(INSTALLER_PATH, "w")
    if not handle then return nil, "cannot write installer (disk full?)" end
    handle.write(body)
    handle.close()
    if not (shell and shell.run) then return nil, "no shell to run the installer" end
    local ok = shell.run(INSTALLER_PATH)
    fs.delete(INSTALLER_PATH)
    if not ok then return nil, "installer failed" end
    return true
end

return updater
