--==============================================================
-- SCREENSHOT SCENES (development only, not installed in game)
--==============================================================

--[[
README
-------
Runs main_control.lua inside the test mock (tests/mock_cc.lua) against
simulated reactors and dumps the monitors at chosen moments. Run through
tools/screenshots/render.py, which turns the dumps into PNGs in docs/ui/.

The plant: a Draconic reactor feeding an energy core, a Bigger Reactors
steam reactor with one turbine, and a Mekanism fission reactor with a
turbine. Two monitors: 57x38 (3x3 at text scale 0.5) and 29x19 (3x3 at
scale 1). Later in the run the Mekanism reactor loses its coolant
supply, which SCRAMs it and raises alarms.

The images are simulations: real monitors draw the same characters and
colours, but this is not a capture from Minecraft.

Dump format, per screen:
  SCREEN <name> <width> <height> <slot>=<rrggbb>;...
  then one line per row of "<char>,<fg>,<bg>" cells.
]]

package.path = "./?.lua;./tests/?.lua;" .. package.path
local out = assert(io.open(arg_out, "w"))
local cc = require("mock_cc"); cc.reset()
local Sim, ErSim, MekSim = require("reactor_sim"), require("er_sim"), require("mek_sim")

-- Plant -------------------------------------------------------------
local de = Sim.new({version = "1.20"})
cc.addPeripheral("draconic_reactor_0", "draconic_reactor", de.reactor)
cc.addPeripheral("flow_gate_0", "flow_gate", de.inGate)
cc.addPeripheral("flow_gate_1", "flow_gate", de.outGate)
settings.set("draconic.inputGate", "flow_gate_0")
settings.set("draconic.outputGate", "flow_gate_1")
cc.addPeripheral("draconic_rf_storage_0", "draconic_rf_storage", {
    getEnergyStored = function() return 4.2e11 end,
    getMaxEnergyStored = function() return 1e12 end,
    getTransferPerTick = function() return 1.25e7 end})
local er = ErSim.new({activelyCooled = true, maxOutput = 3000, turbines = 1, turbineLoad = 6000})
cc.addPeripheral("BigReactors-Reactor_0", "BigReactors-Reactor", er.erReactor)
cc.addPeripheral("BigReactors-Turbine_0", "BigReactors-Turbine", er.erTurbines[1])
local mek = MekSim.new({active = true, burn = 12, temperature = 600, coolantSupply = 0.05})
cc.addPeripheral("fissionReactorPort_0", "fissionReactorPort", mek.fission)
cc.addPeripheral("turbineValve_0", "turbineValve", mek.turbine)

local big, small = cc.newScreen(57, 38), cc.newScreen(29, 19)
cc.addPeripheral("monitor_0", "monitor", big)
cc.addPeripheral("monitor_1", "monitor", small)

local cfg = require("config")
cfg.reactor.autoStartOnBoot = true
cfg.extreme.autoStartOnBoot = true
cfg.ui.graphInterval = 3
cfg.mekanism.targetBurnRate = 15

-- Helpers -------------------------------------------------------------
local function dump(mon, name)
    local w, h = mon.getSize()
    local pal = {}
    for slot, rgb in pairs(mon.palette or {}) do pal[#pal + 1] = string.format("%d=%06x", slot, rgb) end
    out:write("SCREEN " .. name .. " " .. w .. " " .. h .. " " .. table.concat(pal, ";") .. "\n")
    for y = 1, h do
        local cells = {}
        for x = 1, w do
            cells[#cells + 1] = string.format("%d,%d,%d", mon.rows[y]:sub(x, x):byte(),
                                              mon.fgRows[y][x] or 1, mon.bgRows[y][x] or 32768)
        end
        out:write(table.concat(cells, " ") .. "\n")
    end
end

local SIDES = {[big] = "monitor_0", [small] = "monitor_1"}

-- Touch the first occurrence of `needle` (dx = offset from its start;
-- negative dx counts from the right edge of the screen on that row).
local function touch(mon, needle, dx)
    local x, y = mon.find(needle)
    assert(x, needle .. " not on screen:\n" .. mon.text())
    if dx and dx < 0 then x = mon.getSize() + dx + 1 else x = x + (dx or 0) end
    os.queueEvent("monitor_touch", SIDES[mon], x, y)
end

-- Timeline: {seconds, action}. The UI redraws every 0.5 s, so each touch
-- gets its own second before the next dump.
local steps = {
    {25, function() dump(big, "startup_57x38") end},
    {700, function()
        dump(big, "overview_57x38"); dump(small, "overview_29x19")
        touch(big, "DE Reactor"); touch(small, "Reactor")
    end},
    {701, function() dump(big, "detail_57x38"); dump(small, "detail_29x19"); touch(big, " AU ") end},
    {702, function() touch(big, ">>>"); touch(small, " < ") end},
    {703, function() dump(big, "detail_manual_57x38"); touch(big, " MA ") end},
    {704, function() touch(big, " G ") end},
    {705, function() dump(big, "graphs_57x38"); touch(big, " X ") end},
    {706, function() touch(big, " S ") end},
    {707, function() touch(big, "Target Temp", -2) end},
    {708, function() dump(big, "settings_57x38"); touch(big, "RESET") end},
    {709, function() touch(big, "< Back") end},
    {710, function() touch(big, "ER Fission 1") end},
    {711, function() dump(big, "er_reactor_57x38"); touch(big, "< Back") end},
    {712, function() touch(big, "ER Turbine 1") end},
    {713, function() dump(big, "er_turbine_57x38"); touch(big, "< Back") end},
    {714, function() touch(big, "MK Fission 1") end},
    {715, function() dump(big, "mek_fission_57x38"); touch(big, "< Back") end},
    {716, function() touch(big, "Energy Core") end},
    {717, function() dump(big, "storage_57x38"); touch(big, "< Back") end},
    {718, function() touch(big, "Energy Network") end},
    {719, function() dump(big, "network_57x38"); touch(big, "< Back"); mek.coolantSupply = 0 end},
    {780, function() dump(big, "overview_alarm_57x38"); dump(small, "overview_alarm_29x19") end},
    {781, function() touch(big, "MK Fission 1") end},
    {782, function() dump(big, "mek_scram_57x38"); touch(big, "< Back") end},
    {783, function() touch(big, "[i] Overview") end},
    {784, function() dump(big, "system_57x38") end}
}
local last = steps[#steps][1]
for i, s in ipairs(steps) do cc.schedule(s[1], "__step", i) end

local program = assert(loadfile("main_control.lua"))
local carry = 0
local ok, err = cc.run(function()
    local real = os.pullEvent
    os.pullEvent = function(filter)
        while true do
            local ev = {real(filter == "__step" and nil or filter)}
            if ev[1] == "__step" then
                steps[ev[2]][2]()
            elseif filter == nil or ev[1] == filter then
                return table.unpack(ev)
            end
        end
    end
    program()
end, {untilTime = last + 2, onAdvance = function(dt)
    carry = carry + dt
    while carry >= 0.05 - 1e-9 do
        de:tick(); er:tick(); mek:tick()
        carry = carry - 0.05
    end
end})
-- After the program exits: the stale banner, drawn with the stock palette
-- (the mock's stand-in "native" colours are not real ones, so the dump
-- simply leaves every slot at the CC default).
big.palette = {}
dump(big, "stopped_57x38")
out:close()
io.stderr:write(string.format("run finished (%s %s)\n", tostring(ok), tostring(err)))
