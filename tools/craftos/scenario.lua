--==============================================================
-- END-TO-END SCENARIO IN CRAFTOS-PC (development only)
--   craftos --mount-ro /repo=<repo> --exec "shell.run('/repo/tools/craftos/scenario.lua')"
-- or tools/craftos/run_scenario.sh, which also takes screenshots.
--==============================================================

--[[
README
-------
Runs main_control.lua unchanged on CraftOS-PC's ComputerCraft runtime
against the simulated plant (tools/craftos/plant.lua), and drives it like
a player: taps on the monitors (monitor_touch events at the positions
of on-screen text), the simulator's coolant valve, and Ctrl+T at the end.

Every step is checked; results go to /results.txt (PASS/FAIL lines,
then the final text of each monitor) and the computer shuts down. When
a screenshot is wanted it writes the name to /snap_request and waits
for the file to disappear (run_scenario.sh takes the picture).

Monitors are created with periphemu; their text is read back through a
recording proxy around each monitor, because CC monitors cannot be read.
]]

local root = fs.getDir(fs.getDir(fs.getDir(shell.getRunningProgram())))
local function path(p) return "/" .. fs.combine(root, p) end

local results = {}
local function record(ok, name, detail)
    table.insert(results, (ok and "PASS " or "FAIL ") .. name .. (detail and ("  -- " .. detail) or ""))
end

------------------------------------------------------------
-- MONITORS (with text recorders)
------------------------------------------------------------
local recorders = {}

local function newRecorder(dev)
    local r = {rows = {}}
    local cx, cy = 1, 1
    local function reset()
        local w, h = dev.getSize()
        for y = 1, h do r.rows[y] = string.rep(" ", w) end
        for y = h + 1, #r.rows do r.rows[y] = nil end
    end
    local function put(text)
        local row = r.rows[cy]
        if row then
            local w = #row
            for i = 1, #text do
                local x = cx + i - 1
                if x >= 1 and x <= w then row = row:sub(1, x - 1) .. text:sub(i, i) .. row:sub(x + 1) end
            end
            r.rows[cy] = row
        end
        cx = cx + #text
    end
    reset()
    local proxy = {}
    for k, f in pairs(dev) do proxy[k] = f end
    function proxy.setCursorPos(x, y) cx, cy = x, y; return dev.setCursorPos(x, y) end
    function proxy.write(t) t = tostring(t); put(t); return dev.write(t) end
    function proxy.blit(t, f, b) put(t); return dev.blit(t, f, b) end
    function proxy.clear() reset(); return dev.clear() end
    function proxy.clearLine()
        if r.rows[cy] then r.rows[cy] = string.rep(" ", #r.rows[cy]) end
        return dev.clearLine()
    end
    function proxy.setTextScale(s) dev.setTextScale(s); reset() end
    r.dev = proxy
    function r.text() return table.concat(r.rows, "\n") end
    function r.find(needle)
        for y, row in ipairs(r.rows) do
            local x = row:find(needle, 1, true)
            if x then return x, y end
        end
    end
    function r.width() return #(r.rows[1] or "") end
    return r
end

for _, name in ipairs({"top", "left"}) do
    if not peripheral.isPresent(name) then periphemu.create(name, "monitor") end
end
-- run_scenario.sh resizes the monitor windows (3x3 at scale 0.5 and 1)
-- and then creates /ready; without it, carry on after 10 s.
local readyBy = os.clock() + 10
while not fs.exists("/ready") and os.clock() < readyBy do sleep(0.2) end

local plant = dofile(path("tools/craftos/plant.lua"))
local p = assert(plant.setup(root, "all"))

-- Monitors are wrapped once and recorded from then on.
local shimWrap = peripheral.wrap
function peripheral.wrap(name)
    if peripheral.getType(name) == "monitor" then
        recorders[name] = recorders[name] or newRecorder(shimWrap(name))
        return recorders[name].dev
    end
    return shimWrap(name)
end

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local wait = plant.sleep

local function screen(mon) return recorders[mon] and recorders[mon].text() or "" end

local function touchAt(mon, x, y) os.queueEvent("monitor_touch", mon, x, y) end

-- Taps the first occurrence of `needle`; dx > 0 = offset from its start,
-- dx < 0 = column counted from the right edge of the screen.
local function tap(mon, needle, dx)
    local r = recorders[mon]
    local x, y
    if r then x, y = r.find(needle) end
    if not x then
        record(false, "tap '" .. needle .. "' on " .. mon, "not on screen")
        return false
    end
    if dx and dx < 0 then x = r.width() + dx + 1 else x = x + (dx or 0) end
    touchAt(mon, x, y)
    wait(1.2)                  -- the UI redraws every 0.5 s
    return true
end

-- Waits up to `timeout` seconds for `needle` on a monitor.
local function waitFor(mon, needle, timeout)
    local deadline = os.clock() + (timeout or 5)
    repeat
        if screen(mon):find(needle, 1, true) then return true end
        wait(0.5)
    until os.clock() > deadline
    return false
end

local function expect(mon, name, needles, timeout)
    for _, needle in ipairs(needles) do
        if not waitFor(mon, needle, timeout) then
            record(false, name, "'" .. needle .. "' missing")
            return false
        end
    end
    record(true, name)
    return true
end

local function snap(name)
    local f = fs.open("/snap_request", "w")
    f.write(name)
    f.close()
    local deadline = os.clock() + 15
    while fs.exists("/snap_request") and os.clock() < deadline do wait(0.2) end
end

local function logText()
    local f = fs.open("/logs/draconic.log", "r")
    if not f then return "" end
    local text = f.readAll()
    f.close()
    return text
end

------------------------------------------------------------
-- SCENARIO
------------------------------------------------------------
local BIG, SMALL = "top", "left"
local managerDone = false

local function scenario()
    expect(BIG, "overview lists every simulated unit", {"[i] Overview", "DE Reactor", "ER Fission 1",
           "ER Turbine 1", "MK Fission 1", "Energy Core", "Energy Network"}, 20)
    expect(SMALL, "small monitor shows the overview", {"[i] Overview", "DE Reactor"}, 5)
    snap("cpc_overview_cold")

    -- Start the Draconic reactor and the Bigger Reactors reactor + turbine.
    tap(BIG, "DE Reactor")
    expect(BIG, "Draconic page opens", {"Reactor Status", "Field Strength", "START"})
    tap(BIG, "START")
    expect(BIG, "Draconic reactor starts after START", {"WARMING UP"}, 30)
    tap(BIG, "< Back")
    tap(BIG, "ER Fission 1")
    expect(BIG, "Bigger Reactors page opens", {"Control Rods", "Steam Tank"})
    tap(BIG, "START")
    expect(BIG, "Bigger Reactors reactor goes online", {"ONLINE STEAM"}, 10)
    tap(BIG, "< Back")
    tap(BIG, "ER Turbine 1")
    tap(BIG, "START")
    expect(BIG, "turbine starts spinning up", {"SPINNING UP"}, 10)
    tap(BIG, "< Back")

    -- Let the plant come up.
    expect(BIG, "Draconic reactor reaches RUNNING", {"RUNNING"}, 240)
    wait(20)
    snap("cpc_overview_running")

    -- Draconic page: manual output, graphs, settings.
    tap(BIG, "DE Reactor")
    tap(BIG, " AU ")
    expect(BIG, "AU -> manual mode", {" MA ", "Output (man)"})
    tap(BIG, ">>>")
    tap(BIG, " MA ")
    expect(BIG, "MA -> automatic again", {" AU ", "Output Gate"})
    snap("cpc_draconic")
    tap(BIG, " G ")
    expect(BIG, "graphs page", {"Temperature", "Field", "now"})
    snap("cpc_graphs")
    tap(BIG, " X ")
    tap(BIG, " S ")
    expect(BIG, "settings page", {"Target Temp", "PIN HERE", "RESET"})
    tap(BIG, "Target Temp", -2)
    expect(BIG, "+ raises Target Temp to 7,100C", {"7,100C", "def 7,000C"})
    snap("cpc_settings")
    tap(BIG, "RESET")
    if waitFor(BIG, "7,000C", 3) and not screen(BIG):find("7,100C", 1, true) then
        record(true, "RESET restores Target Temp")
    else
        record(false, "RESET restores Target Temp")
    end
    tap(BIG, " X ")
    tap(BIG, "< Back")

    -- Bigger Reactors rods by hand, then back to auto.
    tap(BIG, "ER Fission 1")
    tap(BIG, "+10")
    expect(BIG, "rod buttons switch to manual", {"Rods (manual)", " MA "})
    tap(BIG, " MA ")
    expect(BIG, "rods back to automatic", {"Control Rods", " AU "})
    snap("cpc_bigger_reactors")
    tap(BIG, "< Back")

    -- Mekanism, storage, network pages.
    tap(BIG, "MK Fission 1")
    expect(BIG, "Mekanism fission page", {"Fission Status", "ACTIVE", "SCRAM"})
    tap(BIG, "< Back")
    tap(BIG, "Energy Core")
    expect(BIG, "energy core page", {"Storage", "Stored", "Charge"})
    tap(BIG, "< Back")
    tap(BIG, "Energy Network")
    expect(BIG, "energy network page", {"Network Status", "Generation", "Consumption"})
    tap(BIG, "< Back")

    -- Fault: the Mekanism reactor loses its coolant supply.
    p.mek.coolantSupply = 0
    expect(BIG, "coolant loss SCRAMs the Mekanism reactor", {"SCRAMMED", "! "}, 180)
    expect(BIG, "footer shows the alarm", {"Fission 1: "})
    snap("cpc_alarm")
    local fx, fy = recorders[BIG].find("Fission 1: ")
    if fx then touchAt(BIG, fx, fy); wait(1.5) end
    record(logText():find("Alarm sound silenced", 1, true) ~= nil, "tapping the alarm footer silences")

    -- System page.
    tap(BIG, "[i] Overview")
    expect(BIG, "System page with the alarm listed", {"Version", "v4.2", "Alarms", "SCRAM"})
    snap("cpc_system")
    tap(BIG, "< Back")

    -- The small monitor pages through 7 cards.
    expect(SMALL, "29x19 monitor shows the overview", {"[i] Overview", "1/2"})
    tap(SMALL, " > ")
    expect(SMALL, "29x19 pager goes to page 2", {"2/2"})
    snap("cpc_small")

    -- Ctrl+T: fail-safe, palette restore, stale banner.
    os.queueEvent("terminate")
    local deadline = os.clock() + 20
    while not managerDone and os.clock() < deadline do wait(0.5) end
    record(managerDone, "Ctrl+T stops the manager")
    local log = logText()
    record(log:find("Program exiting", 1, true) ~= nil, "exit is logged with the fail-safe")
    record(screen(BIG):find("MANAGER STOPPED", 1, true) ~= nil, "monitor marked MANAGER STOPPED")
    snap("cpc_stopped")
    local errors = 0
    for line in log:gmatch("[^\n]+") do
        if line:find("%[ERROR%]") or line:find("Display error") then
            errors = errors + 1
            record(false, "log error", line)
        end
    end
    record(errors == 0, "no ERROR lines in the log")
end

local function manager()
    shell.run(path("main_control.lua"))
    managerDone = true
    wait(3600)             -- keep running until the scenario finishes
end

local ok, err = pcall(parallel.waitForAny, manager, function() plant.loop(p) end, scenario)
if not ok then record(false, "scenario crashed", tostring(err)) end

local out = fs.open("/results.txt", "w")
local fails = 0
for _, line in ipairs(results) do
    out.writeLine(line)
    if line:sub(1, 4) == "FAIL" then fails = fails + 1 end
end
out.writeLine(string.format("%d checks, %d failed", #results, fails))
for _, name in ipairs({BIG, SMALL}) do
    out.writeLine("==== " .. name)
    out.writeLine(screen(name))
end
out.close()
os.shutdown()
