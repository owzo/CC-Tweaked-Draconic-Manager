-- Monitor Utilities
-- Save as: monitor_utils.lua

--[[
README

Functions to handle monitor interactions for Draconic Reactor and Energy Core control.
Includes drawing elements on the monitor and handling click events.
]]

local config = require("config").energyCore

local monitor_utils = {}

-- Function to setup monitor
function monitor_utils.setupMonitor()
    monitor.setTextScale(config.monitorScale)
end

-- Function to draw text on the monitor
function monitor_utils.drawText(x, y, text, textColor, bgColor)
    monitor.setCursorPos(x, y)
    monitor.setTextColor(textColor)
    monitor.setBackgroundColor(bgColor)
    monitor.write(text)
end

-- Function to clear the monitor
function monitor_utils.clearMonitor()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monitor.setCursorPos(1, 1)
end

-- Function to draw a box on the monitor
function monitor_utils.drawBox(xMin, xMax, yMin, yMax, title)
    monitor.setBackgroundColor(colors.gray)
    for xPos = xMin, xMax do
        monitor.setCursorPos(xPos, yMin)
        monitor.write(" ")
        monitor.setCursorPos(xPos, yMax)
        monitor.write(" ")
    end
    for yPos = yMin, yMax do
        monitor.setCursorPos(xMin, yPos)
        monitor.write(" ")
        monitor.setCursorPos(xMax, yPos)
        monitor.write(" ")
    end
    monitor.setCursorPos(xMin + 2, yMin)
    monitor.setBackgroundColor(colors.black)
    monitor.write(" ")
    monitor.write(title)
    monitor.write(" ")
end

-- Function to draw a button on the monitor
function monitor_utils.drawButton(xMin, xMax, yMin, yMax, text1, text2, bColor)
    monitor.setBackgroundColor(bColor)
    for yPos = yMin, yMax do
        for xPos = xMin, xMax do
            monitor.setCursorPos(xPos, yPos)
            monitor.write(" ")
        end
    end
    monitor.setCursorPos(math.floor((xMax + xMin) / 2 - string.len(text1) / 2), math.floor((yMax + yMin) / 2))
    monitor.write(text1)
    if text2 then
        monitor.setCursorPos(math.floor((xMax + xMin) / 2 - string.len(text2) / 2), math.floor((yMax + yMin) / 2) + 1)
        monitor.write(text2)
    end
end

-- Function to handle click events on the monitor
function monitor_utils.clickListener()
    while true do
        local event, side, xPos, yPos = os.pullEvent("monitor_touch")
        if xPos >= 2 and xPos <= 9 and yPos >= 16 and yPos <= 18 then
            setInputRate()
        elseif xPos >= 11 and xPos <= 18 and yPos >= 16 and yPos <= 18 then
            setOutputRate()
        end
    end
end

return monitor_utils
