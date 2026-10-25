--==============================================================
-- MONITOR UTILITIES
-- Save as: monitor_utils.lua
--==============================================================

--[[
README
-------
Touchscreen dashboard. Works on any number of monitors and falls back
to the computer's own screen (mouse clicks) when no monitor exists.

  monitor_utils.init(monitorNames, uiCfg)  Prepare display targets
  monitor_utils.render(model)              Redraw every target
  monitor_utils.handleTouch(name, x, y)    Return the action string of the
                                           button at (x, y), or nil

Layout needs 29x17 characters: a 3x3 block advanced monitor at text
scale 1.0, or a 2x2 at scale 0.5 (chosen automatically).

Button actions:
  "out:<delta>"  adjust manual output (switches to manual mode)
  "start"        charge + activate, clear a latched trip
  "stop"         controlled shutdown
  "auto"         toggle automatic output regulation
]]

local monitor_utils = {}

local MIN_WIDTH, MIN_HEIGHT = 29, 17
local TERMINAL = "term"

local targets = {}     -- name -> {name, dev, win, buttons}
local order = {}       -- names in display order
local uiSettings = {manualStep = {1000, 10000, 100000}}

------------------------------------------------------------
-- FORMATTING
------------------------------------------------------------
local SUFFIXES = {{1e12, "T"}, {1e9, "G"}, {1e6, "M"}, {1e3, "k"}}

function monitor_utils.formatRF(value)
    value = tonumber(value) or 0
    local magnitude = math.abs(value)
    for _, s in ipairs(SUFFIXES) do
        if magnitude >= s[1] then
            return string.format("%.1f%s", value / s[1], s[2])
        end
    end
    return string.format("%.0f", value)
end

local function pctColor(pct, low, high)
    if pct < low then return colors.red end
    if pct < high then return colors.orange end
    return colors.green
end

local function tempColor(temp, target, max)
    if temp > max then return colors.red end
    if temp > target + (max - target) * 0.5 then return colors.orange end
    return colors.green
end

local STATUS_COLORS = {
    running = colors.green, warming_up = colors.yellow,
    stopping = colors.orange, cooling = colors.lightBlue,
    cold = colors.lightGray, beyond_hope = colors.red
}

------------------------------------------------------------
-- TARGET SETUP
------------------------------------------------------------
local function pickScale(dev, preferred)
    if preferred then
        dev.setTextScale(preferred)
        return
    end
    for _, scale in ipairs({1, 0.5}) do
        dev.setTextScale(scale)
        local w, h = dev.getSize()
        if w >= MIN_WIDTH and h >= MIN_HEIGHT then
            return
        end
    end
end

local function addTarget(name, dev)
    local w, h = dev.getSize()
    targets[name] = {
        name = name,
        dev = dev,
        win = window.create(dev, 1, 1, w, h, true),
        buttons = {}
    }
    table.insert(order, name)
end

-- monitorNames: list of names, or empty to use every attached monitor.
-- Returns the number of monitors in use (0 = terminal fallback).
function monitor_utils.init(monitorNames, uiCfg)
    targets, order = {}, {}
    for k, v in pairs(uiCfg or {}) do uiSettings[k] = v end

    local names = {}
    if monitorNames and #monitorNames > 0 then
        names = monitorNames
    else
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "monitor" then
                table.insert(names, name)
            end
        end
        table.sort(names)
    end

    for _, name in ipairs(names) do
        if peripheral.isPresent(name) and peripheral.getType(name) == "monitor" then
            local dev = peripheral.wrap(name)
            pickScale(dev, uiSettings.textScale)
            addTarget(name, dev)
        end
    end

    local monitors = #order
    if monitors == 0 then
        addTarget(TERMINAL, term.current())
    end
    return monitors
end

function monitor_utils.usesTerminal()
    return targets[TERMINAL] ~= nil
end

function monitor_utils.targetNames()
    return order
end

------------------------------------------------------------
-- DRAWING PRIMITIVES (operate on a window)
------------------------------------------------------------
local function text(win, x, y, str, fg, bg)
    win.setCursorPos(x, y)
    win.setTextColor(fg or colors.white)
    win.setBackgroundColor(bg or colors.black)
    win.write(str)
end

local function centered(win, y, str, fg, bg, width)
    local x = math.max(1, math.floor((width - #str) / 2) + 1)
    text(win, x, y, str, fg, bg)
end

local function bar(win, y, width, pct, color)
    local inner = width - 2
    local filled = math.floor(math.max(0, math.min(1, pct)) * inner + 0.5)
    win.setCursorPos(2, y)
    win.setBackgroundColor(color)
    win.write(string.rep(" ", filled))
    win.setBackgroundColor(colors.gray)
    win.write(string.rep(" ", inner - filled))
    win.setBackgroundColor(colors.black)
end

local function labelValue(win, y, width, label, value, color)
    text(win, 2, y, label, colors.white)
    text(win, width - #value, y, value, color or colors.white)
end

-- Lays out `defs` ({label, action, color}) as equal buttons across a row.
local function buttonRow(target, y, width, defs)
    local gap = 1
    local count = #defs
    local each = math.floor((width - gap * (count - 1)) / count)
    local x = math.floor((width - (each * count + gap * (count - 1))) / 2) + 1
    for _, def in ipairs(defs) do
        local label = def[1]
        if #label > each then label = label:sub(1, each) end
        local pad = each - #label
        local left = math.floor(pad / 2)
        text(target.win, x, y,
             string.rep(" ", left) .. label .. string.rep(" ", pad - left),
             colors.white, def[3] or colors.blue)
        table.insert(target.buttons, {x1 = x, x2 = x + each - 1, y = y, action = def[2]})
        x = x + each + gap
    end
end

------------------------------------------------------------
-- DASHBOARD
------------------------------------------------------------
--[[
model = {
  info       = reac_utils.readInfo() result or nil,
  controller = reac_utils controller,
  core       = energy_core_utils.read() result or nil,
  limits     = config.reactor,
  events     = stat_utils.recent
}
]]
local function drawDashboard(target, model)
    local win = target.win
    local w, h = win.getSize()
    local info = model.info
    local ctl = model.controller
    local lim = model.limits

    win.setBackgroundColor(colors.black)
    win.clear()
    target.buttons = {}

    if w < MIN_WIDTH or h < MIN_HEIGHT then
        text(win, 1, 1, "Screen too small", colors.red)
        text(win, 1, 2, string.format("Need %dx%d", MIN_WIDTH, MIN_HEIGHT), colors.white)
        return
    end

    win.setBackgroundColor(colors.blue)
    win.setCursorPos(1, 1)
    win.write(string.rep(" ", w))
    centered(win, 1, "DRACONIC REACTOR", colors.white, colors.blue, w)

    if not info then
        centered(win, 3, "REACTOR NOT RESPONDING", colors.red, colors.black, w)
    else
        local status = string.upper((info.status:gsub("_", " ")))
        text(win, 2, 2, "Status:", colors.white)
        text(win, 10, 2, status, STATUS_COLORS[info.status] or colors.red)
        local mode = ctl.autoOutput and "AUTO" or "MANUAL"
        text(win, w - #mode, 2, mode, ctl.autoOutput and colors.green or colors.orange)

        labelValue(win, 3, w, "Generation", monitor_utils.formatRF(info.generationRate) .. " RF/t")

        local tc = tempColor(info.temperature, lim.targetTemperature, lim.maxTemperature)
        labelValue(win, 4, w, "Temperature",
                   string.format("%.0fC / %.0f", info.temperature, lim.targetTemperature), tc)
        bar(win, 5, w, info.temperature / lim.maxTemperature, tc)

        local fc = pctColor(info.fieldPct, lim.minField * 1.5, lim.targetField * 0.9)
        labelValue(win, 6, w, "Field", string.format("%.1f%%", info.fieldPct * 100), fc)
        bar(win, 7, w, info.fieldPct, fc)

        labelValue(win, 8, w, "Saturation", string.format("%.1f%%", info.satPct * 100), colors.lightBlue)
        bar(win, 9, w, info.satPct, colors.lightBlue)

        local fuelC = pctColor(info.fuelRemaining, lim.minFuel, lim.minFuel * 2)
        labelValue(win, 10, w, "Fuel", string.format("%.1f%%", info.fuelRemaining * 100), fuelC)
        bar(win, 11, w, info.fuelRemaining, fuelC)
    end

    text(win, 2, 12, "In " .. monitor_utils.formatRF(ctl.inputRate), colors.white)
    local out = "Out " .. monitor_utils.formatRF(ctl.outputRate)
    text(win, w - #out, 12, out, colors.white)

    local core = model.core
    if core then
        local line = string.format("Core %.1f%% %s", core.pct * 100, monitor_utils.formatRF(core.stored))
        if core.transfer then
            line = line .. " " .. (core.transfer >= 0 and "+" or "") .. monitor_utils.formatRF(core.transfer)
        end
        text(win, 2, 13, line, pctColor(core.pct, 0.1, 0.25))
    else
        text(win, 2, 13, "Core: not connected", colors.lightGray)
    end

    -- Alarm line: alarms beat the latest event.
    local alarm = ctl.alarms[1]
    if alarm then
        centered(win, 14, alarm:sub(1, w), colors.white, colors.red, w)
    elseif model.events and model.events[1] then
        text(win, 2, 14, model.events[1].message:sub(1, w - 2), colors.lightGray)
    end

    local steps = uiSettings.manualStep
    local outRow = h >= MIN_HEIGHT + 1 and 16 or 15
    buttonRow(target, outRow, w, {
        {"<<<", "out:" .. -steps[3], colors.gray},
        {"<<", "out:" .. -steps[2], colors.gray},
        {"<", "out:" .. -steps[1], colors.gray},
        {">", "out:" .. steps[1], colors.gray},
        {">>", "out:" .. steps[2], colors.gray},
        {">>>", "out:" .. steps[3], colors.gray}
    })
    buttonRow(target, h >= MIN_HEIGHT + 2 and 18 or 17, w, {
        {"START", "start", colors.green},
        {"STOP", "stop", colors.red},
        {ctl.autoOutput and "MANUAL" or "AUTO", "auto", colors.blue}
    })
end

function monitor_utils.render(model)
    for _, name in ipairs(order) do
        local target = targets[name]
        local ok = target == nil or pcall(function()
            target.win.setVisible(false)
            drawDashboard(target, model)
            target.win.setVisible(true)
        end)
        if not ok then
            -- Monitor was broken or detached mid-draw; drop it until the
            -- next re-init (triggered by a peripheral event).
            targets[name] = nil
        end
    end
end

-- Returns the action string under (x, y) on display `name`, or nil.
function monitor_utils.handleTouch(name, x, y)
    local target = targets[name]
    if not target then return nil end
    for _, b in ipairs(target.buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then
            return b.action
        end
    end
    return nil
end

monitor_utils.TERMINAL = TERMINAL
return monitor_utils
