--==============================================================
-- Energy Core Utilities (Flux Gate Based)
-- Save as: energy_core_utils.lua
--==============================================================

--[[
README
-------
Monitors energy flow via Draconic Evolution Flux Gates.
No longer connects directly to the Energy Core or I/O Crystals.

Features:
- Detects all flux gates dynamically
- Determines which gate is Input vs Output based on energy flow
- Displays live input/output rates on monitor
- Safe for wired, wireless, or hybrid modem setups
]]

------------------------------------------------------------
-- MODULE SETUP
------------------------------------------------------------
local energy_core_utils = {}

local monitor
local inputGate
local outputGate
local gatesDetected = false

------------------------------------------------------------
-- FLUX GATE DETECTION
------------------------------------------------------------
local function detectFluxGates()
    local gates = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name):find("flux_gate") then
            table.insert(gates, peripheral.wrap(name))
        end
    end

    if #gates == 0 then
        error("No flux gates found! Attach modems to your input/output gates.")
    end

    print("Detecting flux gate directions...")
    for _, gate in ipairs(gates) do
        local ok, flow = pcall(gate.getFlow)
        if ok and type(flow) == "number" then
            if flow < 0 then
                inputGate = gate
            else
                outputGate = gate
            end
        end
    end

    if not inputGate then inputGate = gates[1] end
    if not outputGate then
        for _, g in ipairs(gates) do
            if g ~= inputGate then outputGate = g end
        end
    end

    print("Input Gate:  " .. peripheral.getName(inputGate))
    print("Output Gate: " .. peripheral.getName(outputGate))
    gatesDetected = true
end

------------------------------------------------------------
-- MONITOR SETUP
------------------------------------------------------------
function energy_core_utils.setup()
    detectFluxGates()
    monitor = peripheral.find("monitor")
    if not monitor then
        print("No monitor detected; running headless.")
        return
    end
    monitor.setTextScale(1)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
end

------------------------------------------------------------
-- DISPLAY UPDATE
------------------------------------------------------------
function energy_core_utils.updateMonitor()
    if not monitor then return end
    monitor.clear()
    monitor.setCursorPos(2, 2)
    monitor.setTextColor(colors.white)
    monitor.write("Energy Flow Monitor")

    local inFlow, outFlow = 0, 0
    if inputGate then
        local ok, f = pcall(inputGate.getFlow)
        if ok then inFlow = f end
    end
    if outputGate then
        local ok, f = pcall(outputGate.getFlow)
        if ok then outFlow = f end
    end

    monitor.setCursorPos(2, 4)
    monitor.write(string.format("Input Rate:  %.0f RF/t", inFlow))
    monitor.setCursorPos(2, 5)
    monitor.write(string.format("Output Rate: %.0f RF/t", outFlow))
end

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------
function energy_core_utils.logEnergyCoreStats()
    local f = fs.open("energy_core_stats.log", "a")
    if not f then return end

    local inFlow, outFlow = 0, 0
    if inputGate then
        local ok, fIn = pcall(inputGate.getFlow)
        if ok then inFlow = fIn end
    end
    if outputGate then
        local ok, fOut = pcall(outputGate.getFlow)
        if ok then outFlow = fOut end
    end

    f.writeLine(os.date("%Y-%m-%d %H:%M:%S") ..
        string.format(" | In: %.0f RF/t | Out: %.0f RF/t", inFlow, outFlow))
    f.close()
end

return energy_core_utils
