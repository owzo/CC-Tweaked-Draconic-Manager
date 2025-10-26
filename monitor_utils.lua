--==============================================================
-- Monitor Utilities
-- Save as: monitor_utils.lua
--==============================================================

--[[
README
-------
Functions for all monitor interactions in the Draconic Reactor + Energy Core Manager.

Features:
- Supports wired, wireless, or mixed modem setups
- Works with one or multiple monitors
- Provides safe drawing functions (text, boxes, buttons)
- Handles touchscreen click events for manual input/output controls

Configuration:
Monitor scale and side names come from config.lua.
]]

------------------------------------------------------------
-- DEPENDENCIES AND CONFIG
------------------------------------------------------------
local cfg = require("config")
local energyCfg = cfg.energyCore
local peripherals = cfg.peripherals

local monitor_utils = {}

------------------------------------------------------------
-- LOCAL REFERENCES
------------------------------------------------------------
local monitors = {}

------------------------------------------------------------
-- HELPER FUNCTIONS
------------------------------------------------------------
local function detectMonitors()
    local found = {}
    if peripherals.monitors and #peripherals.monitors > 0 then
        for _, side in ipairs(peripherals.monitors) do
            if peripheral.getType(side) == "monitor" then
                table.insert(found, peripheral.wrap(side))
            end
        end
    end

    -- Fallback to auto-detection if none defined
    if #found == 0 then
        local m = peripheral.find("monitor")
        if m then table.insert(found, m) end
    end

    if #found == 0 then
        error("No monitor found. Please attach or define one in config.peripherals.monitors.")
    end
    return found
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------
function monitor_utils.setupMonitor()
    monitors = detectMonitors()
    for _, mon in ipairs(monitors) do
        mon.setTextScale(energyCfg.monitorScale or 1)
        mon.setBackgroundColor(colors.black)
        mon.clear()
        mon.setCursorPos(1, 1)
    end
end

------------------------------------------------------------
-- DRAWING UTILITIES
------------------------------------------------------------
function monitor_utils.clearMonitor()
    if #monitors == 0 then monitor_utils.setupMonitor() end
    for _, mon in ipairs(monitors) do
        mon.setBackgroundColor(colors.black)
        mon.clear()
        mon.setCursorPos(1, 1)
    end
end

function monitor_utils.drawText(x, y, text, textColor, bgColor)
    if #monitors == 0 then monitor_utils.setupMonitor() end
    for _, mon in ipairs(monitors) do
        mon.setCursorPos(x, y)
        mon.setTextColor(textColor or colors.white)
        mon.setBackgroundColor(bgColor or colors.black)
        mon.write(text)
    end
end

function monitor_utils.drawBox(xMin, xMax, yMin, yMax, title)
    if #monitors == 0 then monitor_utils.setupMonitor() end
    for _, mon in ipairs(monitors) do
        mon.setBackgroundColor(colors.gray)
        for xPos = xMin, xMax do
            mon.setCursorPos(xPos, yMin)
            mon.write(" ")
            mon.setCursorPos(xPos, yMax)
            mon.write(" ")
        end
        for yPos = yMin, yMax do
            mon.setCursorPos(xMin, yPos)
            mon.write(" ")
            mon.setCursorPos(xMax, yPos)
            mon.write(" ")
        end
        if title then
            mon.setCursorPos(xMin + 2, yMin)
            mon.setBackgroundColor(colors.black)
            mon.write(" " .. title .. " ")
        end
    end
end

function monitor_utils.drawButton(xMin, xMax, yMin, yMax, text1, text2, bColor)
    if #monitors == 0 then monitor_utils.setupMonitor() end
    for _, mon in ipairs(monitors) do
        mon.setBackgroundColor(bColor or colors.blue)
        for yPos = yMin, yMax do
            for xPos = xMin, xMax do
                mon.setCursorPos(xPos, yPos)
                mon.write(" ")
            end
        end
        mon.setTextColor(colors.white)
        local midY = math.floor((yMax + yMin) / 2)
        mon.setCursorPos(math.floor((xMax + xMin) / 2 - string.len(text1) / 2), midY)
        mon.write(text1 or "")
        if text2 then
            mon.setCursorPos(math.floor((xMax + xMin) / 2 - string.len(text2) / 2), midY + 1)
            mon.write(text2)
        end
    end
end

------------------------------------------------------------
-- CLICK HANDLING
------------------------------------------------------------
-- The click listener calls global handlers or you can register custom ones.
local inputCallback = nil
local outputCallback = nil

function monitor_utils.setCallbacks(inputFn, outputFn)
    inputCallback = inputFn
    outputCallback = outputFn
end

function monitor_utils.clickListener()
    if #monitors == 0 then monitor_utils.setupMonitor() end
    while true do
        local event, side, xPos, yPos = os.pullEvent("monitor_touch")

        -- Input Rate Button
        if xPos >= 2 and xPos <= 9 and yPos >= 16 and yPos <= 18 then
            if inputCallback then
                inputCallback()
            else
                print("Input button pressed (no callback assigned).")
            end

        -- Output Rate Button
        elseif xPos >= 11 and xPos <= 18 and yPos >= 16 and yPos <= 18 then
            if outputCallback then
                outputCallback()
            else
                print("Output button pressed (no callback assigned).")
            end
        end
    end
end

------------------------------------------------------------
-- UTILITY: DISPLAY MESSAGE ON ALL MONITORS
------------------------------------------------------------
function monitor_utils.displayMessage(message)
    if #monitors == 0 then monitor_utils.setupMonitor() end
    for _, mon in ipairs(monitors) do
        mon.setBackgroundColor(colors.black)
        mon.clear()
        mon.setCursorPos(2, 2)
        mon.setTextColor(colors.white)
        mon.write(message or "No message.")
    end
end

return monitor_utils
