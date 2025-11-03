--==============================================================
-- ENERGY CORE UTILITIES (FLUX GATE BASED)
-- Save as: energy_core_utils.lua
--==============================================================

local cfg = require("config")
local p = cfg.peripherals
local energy_core_utils = {}

local inGate  = peripheral.wrap(p.fluxIn)
local outGate = peripheral.wrap(p.fluxOut)
local mon     = peripheral.wrap(p.monitors[1])

local function log(msg)
    local f = fs.open(cfg.energyCore.logsFile, "a")
    if f then
        f.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " | " .. msg)
        f.close()
    end
end

function energy_core_utils.updateMonitor()
    if not mon then return end
    mon.setTextScale(cfg.energyCore.monitorScale)
    mon.setBackgroundColor(colors.black)
    mon.clear()
    mon.setTextColor(colors.white)

    local okIn, inFlow = pcall(inGate.getFlow)
    local okOut, outFlow = pcall(outGate.getFlow)
    if not okIn or not okOut then
        mon.setCursorPos(2, 2)
        mon.write("Flux Gate Error")
        log("Flux gate communication failed.")
        return
    end

    mon.setCursorPos(2, 2)
    mon.write("Energy Flow Monitor")
    mon.setCursorPos(2, 4)
    mon.write(string.format("Input:  %.0f RF/t", inFlow))
    mon.setCursorPos(2, 5)
    mon.write(string.format("Output: %.0f RF/t", outFlow))
end

function energy_core_utils.logEnergyCoreStats()
    local okIn, inFlow = pcall(inGate.getFlow)
    local okOut, outFlow = pcall(outGate.getFlow)
    if not okIn or not okOut then return end
    local f = fs.open("energy_core_stats.log", "a")
    if f then
        f.writeLine(string.format("%s | In: %.0f RF/t | Out: %.0f RF/t",
            os.date("%Y-%m-%d %H:%M:%S"), inFlow, outFlow))
        f.close()
    end
end

return energy_core_utils
