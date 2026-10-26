--==============================================================
-- MONITOR UTILITIES
-- Save as: monitor_utils.lua
--==============================================================

--[[
README
-------
Touchscreen dashboard. Works on any number of monitors and falls back
to the computer's own screen (mouse clicks) when no monitor exists.

  monitor_utils.init(monitorNames, uiCfg, theme) Prepare display targets
                                           (theme = theme.lua module)
  monitor_utils.render(model)              Redraw every target
  monitor_utils.handleTouch(name, x, y)    Return the action string of the
                                           button at (x, y), or nil
  monitor_utils.shutdown()                 Restore the default palette

Layout needs 29x15 characters and looks best at 29x19 or larger: a 3x3
block advanced monitor at text scale 1.0, or a 2x2 at scale 0.5 (chosen
automatically). Spacer rows are dropped first on smaller screens. From
55 columns (e.g. 3x3 at scale 0.5 = 57x38) the overview shows two
columns of unit cards.

Colours are theme roles (T.ok, T.energy, ...), see theme.lua. Charts
use the 2x3 "teletext" characters (128-159) for six dots per cell.

Button actions:
  "out:<delta>"  adjust manual output (switches to manual mode)
  "start"        charge + activate, clear a latched trip
  "stop"         controlled shutdown
  "auto"         toggle automatic output regulation (AU / MA button)
]]

local monitor_utils = {}

local MIN_WIDTH, MIN_HEIGHT = 29, 15
local TWO_COLUMNS = 55         -- overview width that fits two card columns
local TERMINAL = "term"

local targets = {}     -- name -> {name, dev, win, buttons}
local order = {}       -- names in display order
local uiSettings = {manualStep = {1000, 10000, 100000}}
local themeMod = nil   -- theme.lua, when main_control passes it
local sizes = {}       -- name -> {w, h} after the last setup

------------------------------------------------------------
-- THEME ROLES
------------------------------------------------------------
-- Stock-palette roles, used until init() receives a theme module.
local FALLBACK = {
    bg = "black", panel = "black", panelAlt = "gray", border = "gray",
    text = "white", dim = "lightGray", ok = "green", warn = "orange",
    danger = "red", info = "lightBlue", accent = "purple", energy = "lime",
    heat = "red", coolant = "cyan", field = "blue", bright = "white"
}
local T = {}
for role, name in pairs(FALLBACK) do T[role] = colors[name] end
monitor_utils.T = T

local function useRoles(roles)
    for role, value in pairs(roles) do T[role] = value end
end

-- Text colour that stays readable on a filled background.
local function onColor(bg)
    if bg == T.ok or bg == T.warn or bg == T.info or bg == T.energy
        or bg == T.coolant or bg == T.field or bg == T.bright then
        return T.bg
    end
    if bg == T.danger or bg == T.heat or bg == T.accent then return T.bright end
    return T.text
end

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
    if pct < low then return T.danger end
    if pct < high then return T.warn end
    return T.ok
end

local function tempColor(temp, target, max)
    if temp > max then return T.danger end
    if temp > target + (max - target) * 0.5 then return T.warn end
    return T.heat
end

local function statusColor(status)
    local map = {running = T.ok, warming_up = T.warn, stopping = T.energy,
                 cooling = T.info, cold = T.dim, beyond_hope = T.danger}
    return map[status] or T.danger
end

-- Short mod tag and its colour for card and page titles.
local function tagOf(m)
    local kind, mod = m.kind or "", m.mod or ""
    if kind == "draconic" then return "DE", T.accent end
    if kind:find("^mek_") then return "MK", T.coolant end
    if kind == "fission" or kind == "turbine" then
        return mod:find("Bigger") and "BR" or "ER", T.info
    end
    if kind == "network" then return "NET", T.ok end
    if kind == "meter" then return "AP", T.energy end
    if mod:find("Draconic") then return "DE", T.accent end
    if mod:find("Mekanism") then return "MK", T.coolant end
    if mod:find("Flux") then return "FN", T.field end
    if mod:find("Powah") then return "PW", T.warn end
    return "FE", T.field
end
monitor_utils.tagOf = tagOf

------------------------------------------------------------
-- TARGET SETUP
------------------------------------------------------------
-- Changing the text scale makes CC:Tweaked fire monitor_resize, so the
-- scale is only changed when it has to be (see monitor_utils.needsSetup).
local function pickScale(dev, preferred)
    local current = dev.getTextScale and dev.getTextScale()
    if preferred then
        if current ~= preferred then dev.setTextScale(preferred) end
        return
    end
    local w, h = dev.getSize()
    if current == 1 and w >= MIN_WIDTH and h >= MIN_HEIGHT then return end
    -- Scale 1 halves the character grid of scale 0.5.
    if current == 0.5 and (math.floor(w / 2) < MIN_WIDTH or math.floor(h / 2) < MIN_HEIGHT) then return end
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
    sizes[name] = {w, h}
    if themeMod then themeMod.apply(dev, uiSettings.theme) end
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
function monitor_utils.init(monitorNames, uiCfg, theme)
    targets, order, sizes = {}, {}, {}
    for k, v in pairs(uiCfg or {}) do uiSettings[k] = v end
    if theme then
        themeMod = theme
        useRoles(theme.roles(uiSettings.theme))
    end

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

-- Program exit: puts the stock palette back and stamps the top row so
-- the last (now frozen) screen is not mistaken for live data.
function monitor_utils.shutdown()
    for _, name in ipairs(order) do
        local target = targets[name]
        if target then
            if themeMod then pcall(themeMod.restore, target.dev) end
            pcall(function()
                local w = target.dev.getSize()
                local msg = " MANAGER STOPPED - DATA IS STALE "
                target.dev.setCursorPos(1, 1)
                target.dev.setBackgroundColor(colors.red)
                target.dev.setTextColor(colors.white)
                target.dev.write(string.rep(" ", w))
                target.dev.setCursorPos(math.max(1, math.floor((w - #msg) / 2) + 1), 1)
                target.dev.write(msg:sub(1, w))
            end)
        end
    end
end

-- True when a monitor_resize for `name` is a real change (a monitor
-- grown or shrunk) rather than the echo of our own setTextScale.
function monitor_utils.needsSetup(name)
    local target, size = targets[name], sizes[name]
    if not target or not size then return true end
    local ok, w, h = pcall(target.dev.getSize)
    return not ok or w ~= size[1] or h ~= size[2]
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
    win.setTextColor(fg or T.text)
    win.setBackgroundColor(bg or T.bg)
    win.write(str)
end

local function fill(win, x, y, width, bg)
    if width <= 0 then return end
    text(win, x, y, string.rep(" ", width), T.text, bg)
end

local function centered(win, y, str, fg, bg, width)
    local x = math.max(1, math.floor((width - #str) / 2) + 1)
    text(win, x, y, str, fg, bg)
end

-- Left/right text pair inside columns x .. x + width - 1. The value
-- wins: a long label is cut rather than overlapped.
local function pair(win, x, y, width, label, value, labelColor, valueColor, bg)
    fill(win, x, y, width, bg)
    local room = width - #value - 3
    if #label > room then label = label:sub(1, math.max(0, room)) end
    text(win, x + 1, y, label, labelColor or T.text, bg)
    if #value > width - 1 then value = value:sub(1, width - 1) end
    text(win, x + width - 1 - #value, y, value, valueColor or T.text, bg)
end

-- Half-cell bar: "[" fill "]" across columns x .. x + width - 1, with
-- a dotted track and an optional marker (0-1) such as a target.
local LEFT_HALF = string.char(149)     -- teletext: left column lit
local TRACK = string.char(127)         -- checkerboard
local function barAt(win, x, y, width, pct, color, marker, bg)
    bg = bg or T.bg
    local inner = width - 2
    if inner < 1 then return end
    local halves = math.floor(math.max(0, math.min(1, pct or 0)) * inner * 2 + 0.5)
    text(win, x, y, "[", T.dim, bg)
    for i = 1, inner do
        local cellHalves = halves - (i - 1) * 2
        if cellHalves >= 2 then
            text(win, x + i, y, " ", T.text, color)
        elseif cellHalves == 1 then
            text(win, x + i, y, LEFT_HALF, color, T.bg)
        else
            text(win, x + i, y, TRACK, T.border, T.bg)
        end
    end
    text(win, x + inner + 1, y, "]", T.dim, bg)
    if marker then
        local mx = x + math.max(1, math.min(inner, math.floor(marker * inner + 0.5)))
        win.setCursorPos(mx, y)
        win.setTextColor(T.bright)
        win.write("|")
    end
end

-- Lays out `defs` ({label, action, bg, fg}) across a row. Buttons share
-- the width equally unless `widths` fixes some of them (nil = flexible).
local function buttonGeometry(width, defs, widths)
    local gap = 1
    local count = #defs
    local usable = width - 2 - gap * (count - 1)
    local fixed, flexible = 0, 0
    for i = 1, count do
        if widths and widths[i] then fixed = fixed + widths[i] else flexible = flexible + 1 end
    end
    local each = flexible > 0 and math.floor((usable - fixed) / flexible) or 0
    local sizes, total = {}, 0
    for i = 1, count do
        sizes[i] = (widths and widths[i]) or each
        total = total + sizes[i]
    end
    local x = math.floor((width - (total + gap * (count - 1))) / 2) + 1
    local out = {}
    for i = 1, count do
        out[i] = {x = x, size = sizes[i]}
        x = x + sizes[i] + gap
    end
    return out
end

-- `blank` draws the button faces without labels (extra rows of a tall
-- button); every row is touchable.
local function buttonRow(target, y, width, defs, widths, blank)
    for i, g in ipairs(buttonGeometry(width, defs, widths)) do
        local def = defs[i]
        local label = blank and "" or def[1]
        if #label > g.size then label = label:sub(1, g.size) end
        local pad = g.size - #label
        local left = math.floor(pad / 2)
        local bg = def[3] or T.panelAlt
        text(target.win, g.x, y,
             string.rep(" ", left) .. label .. string.rep(" ", pad - left),
             def[4] or onColor(bg), bg)
        table.insert(target.buttons, {x1 = g.x, x2 = g.x + g.size - 1, y = y, action = def[2]})
    end
end

-- 1234567 -> "1,234,567"
local function formatInt(value)
    local s = string.format("%.0f", tonumber(value) or 0)
    local sign, digits = s:match("^(-?)(%d+)$")
    if not digits then return s end
    local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return sign .. (grouped:gsub("^,", ""))
end
monitor_utils.formatInt = formatInt

-- Full figure when it fits beside its label, compact (53.0M) otherwise.
local function fitRate(label, value, width, unit)
    unit = unit or " rf/t"
    local full = formatInt(value) .. unit
    if #label + #full + 3 <= width then return full end
    return monitor_utils.formatRF(value) .. unit
end

------------------------------------------------------------
-- TELETEXT CHARTS
------------------------------------------------------------
--[[
Characters 128-159 split a cell into 2x3 dots: bit 1 top-left, 2
top-right, 4 middle-left, 8 middle-right, 16 bottom-left. The
bottom-right dot is the background, so a cell needing it is drawn
inverted (complement character, colours swapped). `dots` lists the six
dots in that order plus bottom-right. Returns char, foreground,
background.
]]
function monitor_utils.subCell(dots, fg, bg)
    local bits = 0
    for i = 1, 5 do
        if dots[i] then bits = bits + 2 ^ (i - 1) end
    end
    if dots[6] then
        return string.char(128 + 31 - bits), bg, fg
    end
    return string.char(128 + bits), fg, bg
end

-- Value of dot column `col` (1 .. 2 * width) of a chart.
local function sampleAt(item, col)
    local n = #item.samples
    if item.bars then
        -- Spread the samples across the width with a one-dot gap.
        local per = (item.width * 2) / math.max(1, n)
        local index = math.floor((col - 1) / per) + 1
        local within = (col - 1) - (index - 1) * per
        if per >= 3 and within >= per - 1 then return nil end
        return item.samples[index]
    end
    local offset = item.width * 2 - n
    return item.samples[col - offset]
end

-- Dot level (1 = bottom row of dots) of a value, or nil for a gap.
local function dotLevel(item, v, total)
    if v == nil or v == false then return nil end
    local level = math.floor((v - item.lo) / (item.hi - item.lo) * total + 0.5)
    -- An empty bar stays empty; a line never drops off the chart.
    if item.bars and level < 1 then return nil end
    return math.max(1, math.min(total, level))
end

-- One text row of a chart, row 1 being the top. Bar charts fill up to
-- each value; line charts light the value's dot and join it to the
-- previous one so steep changes stay connected.
local function drawGraphRow(win, x0, y, item)
    local total = item.rows * 3
    for cx = 1, item.width do
        local dots = {}
        for sub = 0, 1 do
            local col = (cx - 1) * 2 + sub + 1
            local level = dotLevel(item, sampleAt(item, col), total)
            local low, high = 1, level
            if not item.bars and level then
                local prev = dotLevel(item, sampleAt(item, col - 1), total) or level
                low, high = math.min(prev, level), math.max(prev, level)
            end
            for dy = 0, 2 do
                -- Dot row counted from the bottom of the chart (1 = lowest).
                local fromBottom = total - ((item.row - 1) * 3 + dy)
                dots[dy * 2 + sub + 1] = level ~= nil and fromBottom >= low and fromBottom <= high
            end
        end
        local ch, fg, bg = monitor_utils.subCell(dots, item.color, T.panel)
        text(win, x0 + cx - 1, y, ch, fg, bg)
    end
end

------------------------------------------------------------
-- DASHBOARD
------------------------------------------------------------
--[[
model = {
  info       = reac_utils.readInfo() result or nil,
  controller = reac_utils controller,
  core       = primary storage info (storage_utils tracker) or nil,
  limits     = config.reactor,
  events     = stat_utils.recent
}

The screen is built as a list of one-row items, then fitted to the
monitor: spacer rows (and the optional energy core block) carry a
priority and the lowest are dropped first when space runs out. A 3x3
monitor at scale 1 (29x19) shows everything except some spacers.
]]
-- Spacer priorities: tall-button rows go first, then the top margin,
-- all spacers between the bar sections together (so they stay evenly
-- spaced), the one above the controls, the one under the status, then
-- optional extras (temperature bar, alarm list).
local PAD, TOP, BARS, CONTROLS, HEADER, EXTRA = 0.5, 1, 2, 3, 4, 5

-- Shared page scaffolding: title row, status line, controls and footer.
local function newPage(model)
    local page = {items = {}}
    function page.add(item) table.insert(page.items, item); return item end
    function page.gap(priority, group) page.add({kind = "gap", priority = priority, group = group}) end
    function page.lr(label, value, color, extra)
        local item = {kind = "lr", label = label, value = value, color = color}
        for k, v in pairs(extra or {}) do item[k] = v end
        return page.add(item)
    end
    function page.bar(pct, color, extra)
        local item = {kind = "bar", pct = pct, color = color}
        for k, v in pairs(extra or {}) do item[k] = v end
        return page.add(item)
    end
    function page.buttons(defs, widths) page.add({kind = "buttons", defs = defs, widths = widths}) end

    -- A button row with a blank face row above and below when there is
    -- room (dropped first on small screens).
    function page.tallButtons(defs, widths)
        page.add({kind = "buttons", defs = defs, widths = widths, blank = true, priority = PAD, group = "pad"})
        page.buttons(defs, widths)
        page.add({kind = "buttons", defs = defs, widths = widths, blank = true, priority = PAD, group = "pad"})
    end

    -- Title row: back to the overview (unless this monitor is pinned or
    -- there is only one unit), mod tag and name, graphs and settings.
    function page.nav(title)
        local nav = model.nav or {}
        local buttons = {}
        if nav.page == "detail" then
            table.insert(buttons, {"G", "nav:graphs", T.info})
            if model.settings and #model.settings > 0 then table.insert(buttons, {"S", "nav:settings", T.warn}) end
        else
            table.insert(buttons, {"X", "nav:detail", T.danger})
        end
        local tag, tagColor = tagOf(model)
        page.add({kind = "nav", back = nav.back, title = title or model.name or "Unit",
                  tag = tag, tagColor = tagColor, buttons = buttons})
    end

    function page.header(label, status, color)
        page.gap(TOP)
        page.nav()
        page.lr(label, status, color)
        page.gap(HEADER)
    end

    function page.controls()
        page.gap(CONTROLS)
        page.tallButtons({{"START", "start", T.ok}, {"STOP", "stop", T.danger}})
        page.add({kind = "footer"})
        return page.items
    end
    return page
end

local LAYOUTS = {}

-- Draconic reactor (drmon-style) ---------------------------------------
function LAYOUTS.draconic(model, w)
    local info, ctl, lim = model.info, model.controller, model.limits
    local page = newPage(model)
    local lr, bar, gap = page.lr, page.bar, page.gap

    local status, sColor = "NO SIGNAL", T.danger
    if info then
        status = string.upper((info.status:gsub("_", " ")))
        sColor = statusColor(info.status)
    end
    page.header("Reactor Status", status, sColor)

    lr("Generation", info and fitRate("Generation", info.generationRate, w) or "--", T.energy)
    local tc = info and tempColor(info.temperature, lim.targetTemperature, lim.maxTemperature) or T.danger
    lr("Temperature", info and (formatInt(info.temperature) .. "C") or "--", tc)
    -- Heat towards the trip limit, with the target marked.
    bar(info and info.temperature / lim.maxTemperature or 0, tc,
        {marker = lim.targetTemperature / lim.maxTemperature, priority = EXTRA, group = "tempbar"})
    lr(ctl.autoOutput and "Output Gate" or "Output (man)",
       fitRate("Output Gate", ctl.outputRate, w), T.energy)

    local steps = uiSettings.manualStep
    page.buttons({
        {"<<<", "out:" .. -steps[3]},
        {"<<", "out:" .. -steps[2]},
        {"<", "out:" .. -steps[1]},
        {ctl.autoOutput and "AU" or "MA", "auto", ctl.autoOutput and T.ok or T.warn},
        {">", "out:" .. steps[1]},
        {">>", "out:" .. steps[2]},
        {">>>", "out:" .. steps[3]}
    })
    lr("Input Gate", fitRate("Input Gate", ctl.inputRate, w), T.info)
    gap(BARS, "bars")

    local sat = info and info.satPct or 0
    lr("Energy Saturation", string.format("%.1f%%", sat * 100), T.field)
    bar(sat, T.field)
    gap(BARS, "bars")

    local field = info and info.fieldPct or 0
    local fc = pctColor(field, lim.minField * 1.5, lim.targetField * 0.9)
    if fc == T.ok then fc = T.coolant end
    lr(string.format("Field Strength T:%d", math.floor(lim.targetField * 100 + 0.5)),
       string.format("%.1f%%", field * 100), fc)
    bar(field, fc, {marker = lim.targetField})
    gap(BARS, "bars")

    local fuel = info and info.fuelRemaining or 0
    local fuelC = pctColor(fuel, lim.minFuel, lim.minFuel * 3)
    if fuelC == T.ok then fuelC = T.accent end
    lr("Fuel", string.format("%.1f%%", fuel * 100), fuelC)
    bar(fuel, fuelC)

    local core = model.core
    if core then
        local cc = pctColor(core.pct, 0.1, 0.25)
        if cc == T.ok then cc = T.field end
        local value = string.format("%.1f%%", core.pct * 100)
        if core.transfer then
            local flow = (core.transfer >= 0 and "+" or "") .. monitor_utils.formatRF(core.transfer)
            if #("Energy Core") + #flow + #value + 4 <= w then value = flow .. "  " .. value end
        end
        -- Kept over every spacer; dropped (label and bar together) only
        -- when the essentials would not fit otherwise.
        gap(BARS, "bars")
        page.add({kind = "lr", label = "Energy Core", value = value, color = cc, priority = 10, group = "core"})
        page.add({kind = "bar", pct = core.pct, color = cc, priority = 10, group = "core"})
    end
    return page.controls()
end

-- Shared status line for Extreme/Bigger units.
local function erStatus(d, onText, onColour)
    if not d then return "NO SIGNAL", T.danger end
    if d.assembled == false then return "UNASSEMBLED", T.warn end
    if d.active then return onText or "ONLINE", onColour or T.ok end
    return "OFFLINE", T.dim
end

-- Extreme / Bigger Reactors fission reactor ----------------------------
function LAYOUTS.fission(model, w)
    local d, ctl, lim = model.data or {}, model.controller, model.limits
    local page = newPage(model)
    local lr, bar, gap = page.lr, page.bar, page.gap
    local ok = model.data and model.data.assembled ~= false

    local status, color = erStatus(model.data, d.activelyCooled and "ONLINE STEAM" or "ONLINE")
    page.header("Reactor Status", status, color)

    if d.activelyCooled then
        lr("Steam", ok and (formatInt(d.steamMade or 0) .. " mB/t") or "--", T.coolant)
    else
        lr("Generation", ok and fitRate("Generation", d.produced or 0, w, " FE/t") or "--", T.energy)
    end
    lr("Fuel Temp", ok and (formatInt(d.fuelTemp or 0) .. "C") or "--", T.heat)
    lr("Casing Temp", ok and (formatInt(d.caseTemp or 0) .. "C") or "--", T.heat)
    lr(ctl.auto and "Control Rods" or "Rods (manual)",
       ok and string.format("%.0f%%", d.rods or 0) or "--", T.info)
    page.buttons({
        {"-10", "rods:-10"},
        {"-1", "rods:-1"},
        {ctl.auto and "AU" or "MA", "auto", ctl.auto and T.ok or T.warn},
        {"+1", "rods:1"},
        {"+10", "rods:10"}
    })
    gap(BARS, "bars")

    local level = 0
    if ok then
        if d.activelyCooled then
            level = (d.steamMax or 0) > 0 and d.steam / d.steamMax or 0
        else
            level = (d.capacity or 0) > 0 and d.stored / d.capacity or 0
        end
    end
    local inBand = level >= lim.bufferLow and level <= lim.bufferHigh
    local bc = inBand and T.ok or (level < lim.bufferLow and T.warn or T.info)
    lr(string.format("%s %d-%d", d.activelyCooled and "Steam Tank" or "Energy Buffer",
                     math.floor(lim.bufferLow * 100 + 0.5), math.floor(lim.bufferHigh * 100 + 0.5)),
       string.format("%.1f%%", level * 100), bc)
    bar(level, bc)
    gap(BARS, "bars")

    local fuel = ok and (d.fuelMax or 0) > 0 and d.fuel / d.fuelMax or 0
    local waste = ok and (d.fuelMax or 0) > 0 and (d.waste or 0) / d.fuelMax or 0
    local fuelC = pctColor(fuel, lim.lowFuel or 0.1, (lim.lowFuel or 0.1) * 3)
    if fuelC == T.ok then fuelC = T.warn end
    lr(string.format("Fuel  Waste %.0f%%", waste * 100), string.format("%.1f%%", fuel * 100), fuelC)
    bar(fuel, fuelC)
    return page.controls()
end

-- Extreme / Bigger Reactors turbine ------------------------------------
local function modeText(mode)
    local map = {["spin-up"] = {"SPINNING UP", T.warn}, run = {"ONLINE", T.ok},
                 idle = {"IDLE (FULL)", T.info}, overspeed = {"OVERSPEED", T.danger}}
    return map[mode]
end

function LAYOUTS.turbine(model, w)
    local d, ctl, lim = model.data or {}, model.controller, model.limits
    local page = newPage(model)
    local lr, bar, gap = page.lr, page.bar, page.gap
    local ok = model.data and model.data.assembled ~= false

    local mode = modeText(ctl.mode) or {"ONLINE", T.ok}
    local status, color = erStatus(model.data, mode[1], mode[2])
    page.header("Turbine Status", status, color)

    lr("Generation", ok and fitRate("Generation", d.produced or 0, w, " FE/t") or "--", T.energy)
    local rpm = ok and d.rpm or 0
    local rc = T.coolant
    if rpm > lim.maxRPM then rc = T.danger
    elseif math.abs(rpm - lim.targetRPM) > lim.targetRPM * 0.05 then rc = T.warn end
    lr(string.format("Rotor T:%d", lim.targetRPM), ok and (formatInt(rpm) .. " RPM") or "--", rc)
    bar(rpm / lim.maxRPM, rc, {marker = lim.targetRPM / lim.maxRPM})
    lr("Steam Flow", ok and (formatInt(d.flow or 0) .. " mB/t") or "--", T.info)
    lr("Coils", ok and (d.coils and "ENGAGED" or "DISENGAGED") or "--",
       d.coils and T.ok or T.dim)
    gap(BARS, "bars")

    local level = ok and (d.capacity or 0) > 0 and d.stored / d.capacity or 0
    lr("Energy Buffer", string.format("%.1f%%", level * 100), T.field)
    bar(level, T.field)
    return page.controls()
end

-- Mekanism ---------------------------------------------------------------
local function mekStatus(d, onText)
    if not d then return "NO SIGNAL", T.danger end
    if d.formed == false then return "NOT FORMED", T.warn end
    return onText, T.ok
end

local function fracBar(page, label, v, color, extra)
    page.lr(label, v and string.format("%.1f%%", v * 100) or "--", color)
    page.bar(v or 0, color, extra)
end

-- Like pctColor, but a healthy level is drawn in `okColor`.
local function levelColor(pct, low, high, okColor)
    local c = pctColor(pct, low, high)
    return c == T.ok and okColor or c
end

function LAYOUTS.mek_fission(model, w)
    local d, ctl, lim = model.data or {}, model.controller, model.limits
    local page = newPage(model)
    local status, color
    if ctl.trip then
        status, color = "SCRAMMED", T.danger
    else
        status, color = mekStatus(model.data, d.active and "ACTIVE" or "OFF")
        if model.data and model.data.formed ~= false and not d.active then color = T.dim end
    end
    page.header("Fission Status", status, color)
    page.lr("Burn", string.format("%.1f / %.1f mB/t", d.burnRate or 0, lim.targetBurnRate or d.burnRate or 0),
            T.energy)
    page.buttons({{"-10", "burn:-10"}, {"-1", "burn:-1"}, {"+1", "burn:1"}, {"+10", "burn:10"}})
    local t = d.temperature or 0
    local tc = t >= lim.maxTemperature - lim.tempMargin and T.warn or T.heat
    if t >= lim.maxTemperature then tc = T.danger end
    page.lr(string.format("Temp (scram %d)", lim.maxTemperature), formatInt(t) .. "K", tc)
    page.bar(t / 1200, tc, {marker = lim.maxTemperature / 1200})
    page.lr("Damage", string.format("%d%%", d.damage or 0), (d.damage or 0) > 0 and T.danger or T.ok)
    page.gap(BARS, "bars")
    fracBar(page, "Coolant", d.coolant,
            levelColor(d.coolant or 0, lim.minCoolant, lim.minCoolant * 2, T.coolant),
            {marker = lim.minCoolant})
    fracBar(page, "Heated Coolant", d.heated, (d.heated or 0) > 0.8 and T.warn or T.info)
    page.gap(BARS, "bars")
    fracBar(page, string.format("Fuel  Waste %.0f%%", (d.waste or 0) * 100), d.fuel,
            levelColor(d.fuel or 0, lim.lowFuel or 0.05, (lim.lowFuel or 0.05) * 3, T.warn))
    page.gap(CONTROLS)
    page.tallButtons({{"START", "start", T.ok}, {"SCRAM", "stop", T.danger}})
    page.add({kind = "footer"})
    return page.items
end

function LAYOUTS.mek_turbine(model, w)
    local d = model.data or {}
    local page = newPage(model)
    page.header("Turbine Status", mekStatus(model.data, "ONLINE"))
    page.lr("Generation", fitRate("Generation", d.production or 0, w, " FE/t"), T.energy)
    page.lr("Steam Flow", formatInt(d.flow or 0) .. " mB/t", T.info)
    page.lr("Dumping", tostring(d.dumping or "--"), T.text)
    page.gap(BARS, "bars")
    fracBar(page, "Steam", d.steam, (d.steam or 0) > 0.9 and T.warn or T.coolant)
    page.gap(BARS, "bars")
    local e = (d.maxEnergy or 0) > 0 and d.energy / d.maxEnergy or nil
    fracBar(page, "Energy Buffer", e, T.field)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

function LAYOUTS.mek_boiler(model, w)
    local d = model.data or {}
    local page = newPage(model)
    page.header("Boiler Status", mekStatus(model.data, "ONLINE"))
    page.lr("Boil Rate", formatInt(d.boilRate or 0) .. " mB/t", T.coolant)
    page.lr("Temperature", formatInt(d.temperature or 0) .. "K", T.heat)
    page.gap(BARS, "bars")
    fracBar(page, "Water", d.water, levelColor(d.water or 0, 0.1, 0.3, T.info))
    page.gap(BARS, "bars")
    fracBar(page, "Steam", d.steam, T.coolant)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

function LAYOUTS.mek_fusion(model, w)
    local d = model.data or {}
    local page = newPage(model)
    page.header("Fusion Status", mekStatus(model.data, d.ignited and "IGNITED" or "COLD"))
    page.lr("Generation", fitRate("Generation", d.production or 0, w, " FE/t"), T.energy)
    page.lr("Plasma", monitor_utils.formatRF(d.plasma or 0) .. "K", T.heat)
    page.lr("Case", monitor_utils.formatRF(d.case or 0) .. "K", T.heat)
    page.lr("Injection", tostring(d.injection or "--"), T.info)
    page.buttons({{"-2", "inj:-2"}, {"+2", "inj:2"}})
    page.gap(BARS, "bars")
    fracBar(page, "D-T Fuel", d.dtFuel, levelColor(d.dtFuel or 0, 0.05, 0.2, T.warn))
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

local function buildLayout(model, w)
    return (LAYOUTS[model.kind] or LAYOUTS.draconic)(model, w)
end

-- Drops the lowest-priority rows (spacers first, then the core block) until
-- the layout fits `h` rows. Returns nil when even the essentials don't.
local function fitLayout(items, h)
    while #items > h do
        local lowest = nil
        for _, item in ipairs(items) do
            if item.priority and (not lowest or item.priority < lowest) then
                lowest = item.priority
            end
        end
        if not lowest then return nil end
        local group
        for _, item in ipairs(items) do
            if item.priority == lowest then group = item.group; break end
        end
        local kept = {}
        for _, item in ipairs(items) do
            local drop = item.priority == lowest or (group and item.group == group)
            if not drop then table.insert(kept, item) end
        end
        items = kept
    end
    return items
end

-- Keeps the footer on the bottom row of a screen with rows to spare.
local function pinFooter(items, h)
    if not items or #items >= h or items[#items].kind ~= "footer" then return items end
    local footer = table.remove(items)
    while #items < h - 1 do table.insert(items, {kind = "gap"}) end
    table.insert(items, footer)
    return items
end

-- Energy storage, meters and the energy network ----------------------
-- All in FE (= RF) per tick; see storage_utils.lua.
local function signedRF(v)
    if v == nil then return "--" end
    return (v > 0 and "+" or "") .. monitor_utils.formatRF(v)
end
monitor_utils.signedRF = signedRF

local function flowColor(v)
    if v == nil then return T.dim end
    return v < 0 and T.warn or T.ok
end

-- Seconds -> "45s" / "12m 05s" / "3h 20m" / "2d 04h".
local function duration(seconds)
    if not seconds or seconds ~= seconds then return "--" end
    if seconds > 99 * 86400 then return ">99d" end
    seconds = math.floor(seconds + 0.5)
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return string.format("%dm %02ds", math.floor(seconds / 60), seconds % 60) end
    if seconds < 86400 then
        return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
    end
    return string.format("%dd %02dh", math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600))
end

local function etaRow(page, i)
    if i and i.timeToFull then
        page.lr("Full in", duration(i.timeToFull), T.ok)
    elseif i and i.timeToEmpty then
        page.lr("Empty in", duration(i.timeToEmpty), T.warn)
    else
        page.lr("Full/Empty in", "--", T.dim)
    end
end

local function chargeColor(pct)
    return levelColor(pct, 0.1, 0.25, T.field)
end

local function chargeRows(page, pct)
    local c = chargeColor(pct)
    page.lr("Charge", string.format("%.1f%%", pct * 100), c)
    page.bar(pct, c)
end

local function storageStatus(i)
    if not i then return "NO SIGNAL", T.danger end
    if i.formed == false then return "NOT FORMED", T.warn end
    if i.saturated then return "OVER 2.1G", T.warn end
    return "ONLINE", T.ok
end

function LAYOUTS.storage(model, w)
    local i = model.info
    local ok = i and i.max ~= nil
    local page = newPage(model)
    local status, sc = storageStatus(i)
    page.header("Storage", status, sc)
    page.lr("Stored", ok and (monitor_utils.formatRF(i.stored) .. " FE") or "--", T.energy)
    page.lr("Capacity", ok and (monitor_utils.formatRF(i.max) .. " FE") or "--", T.text)
    page.lr("Input", ok and i.input and (monitor_utils.formatRF(i.input) .. " FE/t") or "--", T.info)
    page.lr("Output", ok and i.output and (monitor_utils.formatRF(i.output) .. " FE/t") or "--", T.info)
    local net = ok and i.net
    page.lr(ok and not i.measured and "Net (est.)" or "Net Flow",
            net and (signedRF(net) .. " FE/t") or "--", flowColor(net or nil))
    etaRow(page, ok and i)
    page.gap(BARS, "bars")
    chargeRows(page, ok and i.pct or 0)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

function LAYOUTS.meter(model, w)
    local i = model.info
    local page = newPage(model)
    page.header("Energy Meter", i and "ONLINE" or "NO SIGNAL", i and T.ok or T.danger)
    page.lr("Flow", i and (fitRate("Flow", i.rate, w, " FE/t")) or "--", T.energy)
    page.lr("Limit", i and i.limit and (fitRate("Limit", i.limit, w, " FE/t")) or "--", T.text)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

local function networkState(state)
    local map = {charging = {"CHARGING", T.ok}, draining = {"DRAINING", T.warn},
                 balanced = {"BALANCED", T.info}}
    return map[state]
end

function LAYOUTS.network(model, w)
    local a = model.info
    local page = newPage(model)
    local st = a and networkState(a.state) or {"NO DATA", T.danger}
    page.header("Network Status", st[1], st[2])
    page.lr("Generation", a and fitRate("Generation", a.generation, w, " FE/t") or "--", T.energy)
    page.lr("Consumption", a and fitRate("Consumption", a.consumption, w, " FE/t") or "--", T.warn)
    page.lr("Storage Net", a and (signedRF(a.net) .. " FE/t") or "--", flowColor(a and a.net))
    page.lr("Stored", a and (monitor_utils.formatRF(a.stored) .. " / " .. monitor_utils.formatRF(a.capacity))
            or "--", T.text)
    etaRow(page, a)
    page.gap(BARS, "bars")
    chargeRows(page, a and a.pct or 0)
    page.gap(CONTROLS)
    page.add({kind = "footer"})
    return page.items
end

------------------------------------------------------------
-- OVERVIEW CARDS
------------------------------------------------------------
-- Each returns status, statusColor, line label, line value, value
-- colour, bar fraction, bar colour, power (for the total).
local CARDS = {}

local function noSignal(status)
    return status or "NO SIGNAL", status and T.warn or T.danger, "--", "--", T.dim, 0, T.panelAlt, 0
end

function CARDS.draconic(m)
    local i, ctl, lim = m.info, m.controller, m.limits
    if not i then return noSignal() end
    return string.upper((i.status:gsub("_", " "))), statusColor(i.status),
        "Out " .. monitor_utils.formatRF(ctl.outputRate),
        formatInt(i.temperature) .. "C", tempColor(i.temperature, lim.targetTemperature, lim.maxTemperature),
        i.fieldPct, levelColor(i.fieldPct, lim.minField * 1.5, lim.targetField * 0.9, T.coolant), ctl.outputRate
end

function CARDS.fission(m)
    local d, lim = m.data, m.limits
    if not d or d.assembled == false then return noSignal(d and "UNASSEMBLED") end
    local level = d.activelyCooled and ((d.steamMax or 0) > 0 and d.steam / d.steamMax or 0)
        or ((d.capacity or 0) > 0 and d.stored / d.capacity or 0)
    local line = d.activelyCooled and ("Steam " .. formatInt(d.steamMade or 0) .. " mB/t")
        or ("Gen " .. monitor_utils.formatRF(d.produced or 0) .. " FE/t")
    local inBand = level >= lim.bufferLow and level <= lim.bufferHigh
    return d.active and "ONLINE" or "OFFLINE", d.active and T.ok or T.dim,
        line, string.format("%.0f%%", level * 100), inBand and T.ok or T.warn,
        level, inBand and T.ok or T.warn, d.activelyCooled and 0 or (d.produced or 0)
end

function CARDS.turbine(m)
    local d, ctl, lim = m.data, m.controller, m.limits
    if not d or d.assembled == false then return noSignal(d and "UNASSEMBLED") end
    local mode = (d.active and modeText(ctl.mode)) or {"OFFLINE", T.dim}
    local rc = math.abs(d.rpm - lim.targetRPM) <= lim.targetRPM * 0.05 and T.coolant or T.warn
    return mode[1], mode[2], "Gen " .. monitor_utils.formatRF(d.produced or 0) .. " FE/t",
        formatInt(d.rpm) .. " RPM", rc, d.rpm / lim.maxRPM, rc, d.produced or 0
end

function CARDS.mek_fission(m)
    local d, ctl = m.data, m.controller
    if not d or d.formed == false then return noSignal(d and "NOT FORMED") end
    local status = ctl.trip and "SCRAMMED" or (d.active and "ACTIVE" or "OFF")
    local sc = ctl.trip and T.danger or (d.active and T.ok or T.dim)
    return status, sc, string.format("Burn %.1f mB/t", d.burnRate or 0),
        formatInt(d.temperature or 0) .. "K", (d.damage or 0) > 0 and T.danger or T.heat,
        d.coolant or 0, levelColor(d.coolant or 0, m.limits.minCoolant, m.limits.minCoolant * 2, T.coolant), 0
end

local function mekSimple(line, value, pct, role)
    return function(m)
        local d = m.data
        if not d or d.formed == false then return noSignal(d and "NOT FORMED") end
        return "ONLINE", T.ok, line(d), value(d), T.text, pct(d) or 0, T[role],
            (m.kind == "mek_turbine" or m.kind == "mek_fusion") and (d.production or 0) or 0
    end
end
CARDS.mek_turbine = mekSimple(function(d) return "Gen " .. monitor_utils.formatRF(d.production or 0) .. " FE/t" end,
    function(d) return string.format("Steam %.0f%%", (d.steam or 0) * 100) end,
    function(d) return d.steam end, "coolant")
CARDS.mek_boiler = mekSimple(function(d) return "Boil " .. formatInt(d.boilRate or 0) .. " mB/t" end,
    function(d) return string.format("Water %.0f%%", (d.water or 0) * 100) end,
    function(d) return d.water end, "info")
CARDS.mek_fusion = mekSimple(function(d) return "Gen " .. monitor_utils.formatRF(d.production or 0) .. " FE/t" end,
    function(d) return d.ignited and "IGNITED" or "COLD" end,
    function(d) return d.dtFuel end, "warn")

function CARDS.storage(m)
    local i = m.info
    if not i or not i.max then
        local status, sc = storageStatus(i)
        return status, sc, "--", "--", T.dim, 0, T.panelAlt, 0
    end
    local c = chargeColor(i.pct)
    local status, sc = "STORAGE", T.info
    if i.net then status, sc = signedRF(i.net) .. "/t", flowColor(i.net) end
    return status, sc, "Stored " .. monitor_utils.formatRF(i.stored),
        string.format("%.1f%%", i.pct * 100), c, i.pct, c, 0
end

function CARDS.meter(m)
    local i = m.info
    if not i then return noSignal() end
    return "METER", T.info, "Flow", monitor_utils.formatRF(i.rate) .. " FE/t",
        T.energy, 0, T.panelAlt, 0
end

function CARDS.network(m)
    local a = m.info
    if not a then return "NO DATA", T.danger, "--", "--", T.dim, 0, T.panelAlt, 0 end
    local st = networkState(a.state) or networkState("balanced")
    return st[1], st[2], "Use " .. monitor_utils.formatRF(a.consumption),
        signedRF(a.net) .. "/t", flowColor(a.net), a.pct, chargeColor(a.pct), 0
end

-- Card contents for one unit.
local function cardOf(m)
    local status, sc, line, value, vc, pct, bc = CARDS[m.kind](m)
    local tag, tagColor = tagOf(m)
    local alarm = m.controller and m.controller.alarms and m.controller.alarms[1]
    return {name = m.name, tag = tag, tagColor = tagColor, status = status, sc = sc,
            line = line, value = value, vc = vc, pct = pct, bc = bc, alarm = alarm,
            action = "nav:detail:" .. m.id}
end

-- Alarm strip (white on red) inside a card.
local function cardAlarm(win, x, y, cw, alarm)
    fill(win, x, y, cw, T.danger)
    text(win, x + 1, y, ("! " .. alarm):sub(1, cw - 2), T.bright, T.danger)
end

-- One text row of a card at columns x .. x + cw - 1. Short (3-row)
-- cards show an alarm in place of the metric line.
local function drawCardLine(target, x, y, cw, card, line, lines)
    local win = target.win
    if line == 1 then
        fill(win, x, y, cw, T.panel)
        local status = card.status
        -- The mod tag gives way before the name is cut.
        local nx = x + 1
        if #card.tag + #card.name + #status + 4 <= cw then
            text(win, nx, y, card.tag, card.tagColor, T.panel)
            nx = nx + #card.tag + 1
        end
        local room = x + cw - 2 - #status - nx
        text(win, nx, y, card.name:sub(1, math.max(0, room)), T.text, T.panel)
        text(win, x + cw - 1 - #status, y, status, card.sc, T.panel)
    elseif line == 2 then
        if lines == 3 and card.alarm then
            cardAlarm(win, x, y, cw, card.alarm)
        else
            pair(win, x, y, cw, card.line, card.value, T.dim, card.vc, T.panel)
        end
    elseif line == 3 then
        fill(win, x, y, cw, T.panel)
        barAt(win, x + 1, y, cw - 2, card.pct, card.bc, nil, T.panel)
    elseif card.alarm then
        cardAlarm(win, x, y, cw, card.alarm)
    else
        fill(win, x, y, cw, T.panel)
        text(win, x + cw - 1 - #"no alarms", y, "no alarms", T.dim, T.panel)
    end
    table.insert(target.buttons, {x1 = x, x2 = x + cw - 1, y = y, action = card.action})
end

local function buildOverview(units, w, h, view)
    local page = newPage({})
    local total, alarms = 0, {}
    for _, m in ipairs(units) do
        local fn = CARDS[m.kind]
        if fn then total = total + (select(8, fn(m)) or 0) end
        local a = m.controller and m.controller.alarms and m.controller.alarms[1]
        if a then table.insert(alarms, m.name .. ": " .. a) end
    end
    -- Tap the top bar for the System page (version, updates, totals, alarms).
    page.add({kind = "topbar", value = monitor_utils.formatRF(total) .. " rf/t", action = "nav:system"})
    -- Energy network line (consumption, storage flow and charge) when any
    -- storage is attached.
    local headerRows = 1
    for _, m in ipairs(units) do
        if m.kind == "network" and m.info then
            local a = m.info
            page.add({kind = "lr", label = "Use " .. monitor_utils.formatRF(a.consumption),
                      value = signedRF(a.net) .. " " .. string.format("%.0f%%", a.pct * 100),
                      color = flowColor(a.net), action = "nav:detail:" .. m.id})
            headerRows = 2
            break
        end
    end

    -- Cards: two columns on wide screens; 4 rows each (name, metric,
    -- bar, alarm) on tall screens, 3 otherwise; a spacer row between.
    local cols = w >= TWO_COLUMNS and 2 or 1
    local avail = h - headerRows - 2           -- spacer under the header, footer
    local lines = h >= 24 and 4 or 3
    local rowsPerPage = math.max(1, math.floor((avail + 1) / (lines + 1)))
    local perPage = rowsPerPage * cols
    local pages = math.max(1, math.ceil(#units / perPage))
    view.overviewPage = math.max(1, math.min(view.overviewPage or 1, pages))
    local first = (view.overviewPage - 1) * perPage + 1
    local cw = cols == 2 and math.floor((w - 3) / 2) or (w - 2)
    page.gap(nil)
    local shown = {}
    for n = first, math.min(#units, first + perPage - 1) do table.insert(shown, cardOf(units[n])) end
    local cardRows = math.ceil(#shown / cols)
    for r = 1, cardRows do
        local row = {}
        for c = 1, cols do row[c] = shown[(r - 1) * cols + c] end
        for line = 1, lines do
            page.add({kind = "cards", cards = row, line = line, lines = lines, cw = cw})
        end
        if r < cardRows then page.gap(nil) end
    end
    page.add({kind = "footer", alarms = alarms,
              pager = pages > 1 and {page = view.overviewPage, pages = pages} or nil})
    return page.items
end

------------------------------------------------------------
-- SETTINGS PAGE
------------------------------------------------------------
local function buildSettings(model, w)
    local page = newPage(model)
    page.gap(TOP)
    page.nav(model.name .. " Settings")
    page.gap(HEADER)
    local defaults = model.defaults or {}
    for _, item in ipairs(model.settings or {}) do
        local value = model.limits[item.key]
        local default = defaults[item.key]
        page.add({kind = "setting", label = item.label, key = item.key,
                  value = model.formatSetting(item, value),
                  default = default ~= nil and model.formatSetting(item, default) or nil,
                  changed = default ~= nil and value ~= default})
        page.gap(PAD, "setting")
    end
    page.gap(CONTROLS)
    page.buttons({
        {model.nav.pinned and "UNPIN" or "PIN HERE", "pin", model.nav.pinned and T.warn or T.panelAlt},
        {"RESET", "reset", T.danger}
    })
    page.add({kind = "footer"})
    return page.items
end

------------------------------------------------------------
-- GRAPHS
------------------------------------------------------------
local HISTORY_SIZE = 300
local history = {}             -- unit id -> {metric index -> samples}

-- Metrics per unit kind: {label, value, max (nil = autoscale), colour, fmt}
local function metricsOf(m)
    local lim = m.limits or {}
    if m.kind == "draconic" then
        local i, ctl = m.info, m.controller
        return {
            {"Temperature", i and i.temperature, lim.maxTemperature, T.heat, "temp"},
            {"Field", i and i.fieldPct, 1, T.coolant, "pct"},
            {"Saturation", i and i.satPct, 1, T.field, "pct"},
            {"Output", ctl and ctl.outputRate, nil, T.energy, "rate"}
        }
    elseif m.kind == "fission" then
        local d = m.data or {}
        local level, production = 0, 0
        if d.activelyCooled then
            level = (d.steamMax or 0) > 0 and d.steam / d.steamMax or 0
            production = d.steamMade
        else
            level = (d.capacity or 0) > 0 and d.stored / d.capacity or 0
            production = d.produced
        end
        return {
            {d.activelyCooled and "Steam Tank" or "Buffer", m.data and level, 1, T.ok, "pct"},
            {d.activelyCooled and "Steam mB/t" or "Generation", production, nil, T.energy, "rate"},
            {"Rods", d.rods, 100, T.info, "int"}
        }
    elseif m.kind == "turbine" then
        local d = m.data or {}
        return {
            {"Rotor RPM", d.rpm, lim.maxRPM, T.coolant, "int"},
            {"Generation", d.produced, nil, T.energy, "rate"},
            {"Steam Flow", d.flow, d.flowLimit, T.info, "int"}
        }
    elseif m.kind == "mek_fission" then
        local d = m.data or {}
        return {
            {"Temperature K", d.temperature, 1200, T.heat, "int"},
            {"Burn mB/t", d.burnRate, d.maxBurnRate, T.energy, "num"},
            {"Coolant", d.coolant, 1, T.coolant, "pct"},
            {"Heated", d.heated, 1, T.info, "pct"}
        }
    elseif m.kind == "mek_turbine" then
        local d = m.data or {}
        return {{"Generation", d.production, nil, T.energy, "rate"},
                {"Steam", d.steam, 1, T.coolant, "pct"}}
    elseif m.kind == "mek_boiler" then
        local d = m.data or {}
        return {{"Boil mB/t", d.boilRate, d.maxBoilRate, T.coolant, "int"},
                {"Water", d.water, 1, T.info, "pct"}}
    elseif m.kind == "mek_fusion" then
        local d = m.data or {}
        return {{"Generation", d.production, nil, T.energy, "rate"},
                {"Plasma K", d.plasma, nil, T.heat, "rate"}}
    elseif m.kind == "storage" then
        local i = m.info
        return {
            {"Charge", i and i.pct, 1, T.field, "pct"},
            {"Net Flow", i and i.net, nil, T.ok, "rate"},
            {"Input", i and i.input, nil, T.info, "rate"},
            {"Output", i and i.output, nil, T.warn, "rate"}
        }
    elseif m.kind == "meter" then
        local i = m.info
        return {{"Flow", i and i.rate, nil, T.energy, "rate"}}
    elseif m.kind == "network" then
        local a = m.info
        return {
            {"Generation", a and a.generation, nil, T.energy, "rate"},
            {"Consumption", a and a.consumption, nil, T.warn, "rate"},
            {"Storage Net", a and a.net, nil, T.info, "rate"},
            {"Charge", a and a.pct, 1, T.field, "pct"}
        }
    end
    return {}
end

-- Records one sample per metric for every unit (called on a timer).
function monitor_utils.sample(units)
    for _, m in ipairs(units) do
        local h = history[m.id] or {}
        history[m.id] = h
        for i, metric in ipairs(metricsOf(m)) do
            h[i] = h[i] or {}
            table.insert(h[i], tonumber(metric[2]) or false)
            if #h[i] > HISTORY_SIZE then table.remove(h[i], 1) end
        end
    end
end

local function fmtMetric(v, fmt)
    if v == nil or v == false then return "--" end
    if fmt == "temp" then return formatInt(v) .. "C" end
    if fmt == "pct" then return string.format("%.0f%%", v * 100) end
    if fmt == "rate" then return monitor_utils.formatRF(v) end
    if fmt == "num" then return string.format("%.1f", v) end
    return formatInt(v)
end

-- Seconds -> "-10m" style axis label.
local function spanLabel(seconds)
    if seconds >= 3600 then return string.format("-%dh", math.floor(seconds / 3600 + 0.5)) end
    if seconds >= 60 then return string.format("-%dm", math.floor(seconds / 60 + 0.5)) end
    return string.format("-%ds", math.floor(seconds + 0.5))
end

-- Adds a chart: title row (label, scale, current value), `rows` dot
-- rows and an axis row (dropped first when space is short). Bar charts
-- start at zero; line charts zoom to the range of their samples.
local function addChart(page, spec)
    local samples, lo, hi = spec.samples, nil, nil
    for _, v in ipairs(samples) do
        if v then
            lo = math.min(lo or v, v)
            hi = math.max(hi or v, v)
        end
    end
    local note
    if spec.bars then
        lo, hi = math.min(0, lo or 0), hi or 1
        if hi <= lo then hi = lo + 1 end
        note = "max " .. fmtMetric(hi, spec.fmt)
    else
        lo, hi = lo or 0, hi or 1
        note = fmtMetric(lo, spec.fmt) .. " - " .. fmtMetric(hi, spec.fmt)
        -- At least +/-5% of the value, so sensor jitter stays flat.
        local pad = math.max((hi - lo) * 0.15, math.abs(hi) * 0.05, 1e-6)
        local floor = lo >= 0 and 0 or -math.huge
        lo, hi = math.max(floor, lo - pad), hi + pad
        if spec.max then hi = math.min(hi, spec.max * 1.05) end
        if hi <= lo then hi = lo + 1 end
    end
    page.add({kind = "lr", label = spec.label, value = fmtMetric(spec.current, spec.fmt),
              color = spec.color, note = note})
    for r = 1, spec.rows do
        page.add({kind = "graph", samples = samples, lo = lo, hi = hi, row = r, rows = spec.rows,
                  color = spec.color, width = spec.width, bars = spec.bars})
    end
    page.add({kind = "axis", left = spec.span, right = "now", priority = TOP, group = "axis"})
end

local function buildGraphs(model, w, h)
    local page = newPage(model)
    page.gap(TOP)
    page.nav(model.name .. " Graphs")
    local metrics = metricsOf(model)
    local hist = history[model.id] or {}
    local interval = uiSettings.graphInterval or 5
    -- Energy per hour over the last day, from the long-term totals.
    if model.hourly then
        local hourly = {}
        for i, v in ipairs(model.hourly) do hourly[i] = v end
        table.insert(metrics, 1, {"Energy/h (24h)", hourly[#hourly], nil, T.energy, "rate", bars = true})
        hist = {hourly}
        for i, series in pairs(history[model.id] or {}) do hist[i + 1] = series end
    end
    -- Each chart: title, at least 2 dot rows, axis (4 rows).
    local free = h - 3                     -- top gap, nav, footer
    local charts = math.max(1, math.min(#metrics, math.floor(free / 4)))
    local rows = math.max(1, math.floor(free / charts) - 2)
    local width = w - 2
    for c = 1, charts do
        local metric = metrics[c]
        local series = hist[c] or {}
        local samples = {}
        local keep = metric.bars and #series or width * 2
        for k = math.max(1, #series - keep + 1), #series do table.insert(samples, series[k]) end
        addChart(page, {label = metric[1], current = metric[2], max = metric[3], color = metric[4],
                        fmt = metric[5], samples = samples, rows = rows, width = width, bars = metric.bars,
                        span = metric.bars and "-24h" or spanLabel(#samples * interval)})
    end
    page.add({kind = "footer"})
    return page.items
end

-- Detail pages on tall screens: live trend charts of the unit's first
-- metrics in the spare rows, just above the controls.
local function addTrends(items, model, w, h)
    local spare = h - #items
    local metrics = metricsOf(model)
    local charts = math.min(2, #metrics, math.floor(spare / 7))
    if charts < 1 then return items end
    local anchor = #items
    for i, item in ipairs(items) do
        if item.priority == CONTROLS or item.kind == "footer" then anchor = i; break end
    end
    local rows = math.min(8, math.floor(spare / charts) - 3)
    local hist = history[model.id] or {}
    local page = newPage(model)
    for c = 1, charts do
        local metric, series, samples = metrics[c], hist[c] or {}, {}
        for k = math.max(1, #series - (w - 2) * 2 + 1), #series do table.insert(samples, series[k]) end
        page.gap(nil)
        addChart(page, {label = metric[1], current = metric[2], max = metric[3], color = metric[4],
                        fmt = metric[5], samples = samples, rows = rows, width = w - 2,
                        span = spanLabel(#samples * (uiSettings.graphInterval or 5))})
    end
    for i, item in ipairs(page.items) do table.insert(items, anchor + i - 1, item) end
    return items
end

------------------------------------------------------------
-- SYSTEM PAGE
------------------------------------------------------------
--[[
view.system = {
  version, update = {text, color, confirm}, alarms = {count, silenced},
  alarmList = {{unit, text}}, logShipping = {enabled, queued, failing}
  or nil, hourly = network energy per hour (oldest first), lifetime
}
]]
local function buildSystem(view, w, h)
    local sys = view.system or {}
    local page = newPage({nav = {back = true, page = "system"}, name = "System"})
    page.gap(TOP)
    page.add({kind = "nav", back = true, title = "System", tag = "CC", tagColor = T.info, buttons = {}})
    page.lr("Version", "v" .. tostring(sys.version or "?"), T.accent)
    local upd = sys.update or {}
    page.lr("Update", upd.text or "not checked", upd.color or T.dim)
    page.buttons({{"CHECK", "sys:check", T.panelAlt},
                  {upd.confirm and "CONFIRM" or "UPDATE", "sys:update",
                   upd.confirm and T.warn or T.info}})
    page.gap(BARS)
    local hourly = sys.hourly or {}
    local today = 0
    for _, v in ipairs(hourly) do today = today + v end
    page.lr("Energy 24h", monitor_utils.formatRF(today), T.energy)
    page.lr("Lifetime", monitor_utils.formatRF(sys.lifetime or 0), T.energy)
    local list = sys.alarmList or {}
    local listRows = math.min(#list, math.max(0, h - 19))
    local rows = math.max(1, math.min(6, h - 15 - listRows))
    addChart(page, {label = "Network energy/h", current = hourly[#hourly], color = T.energy,
                    fmt = "rate", samples = hourly, rows = rows, width = w - 2, bars = true, span = "-24h"})
    page.gap(BARS)
    local al = sys.alarms or {}
    page.lr("Alarms", (al.count or 0) == 0 and "none"
            or (tostring(al.count) .. (al.silenced and " (silenced)" or " active")),
            (al.count or 0) == 0 and T.ok or T.danger)
    for i = 1, listRows do
        page.lr(list[i].unit, list[i].text, T.danger, {labelColor = T.dim, priority = EXTRA, group = "alarmlist"})
    end
    local ship = sys.logShipping
    if ship then
        local value, color = "off", T.dim
        if ship.enabled then
            value = (ship.failing and "FAILING, " or "OK, ") .. tostring(ship.queued or 0) .. " queued"
            color = ship.failing and T.danger or T.ok
        end
        page.lr("Log shipping", value, color, {priority = EXTRA, group = "ship"})
    end
    page.buttons({{"SILENCE", "alarm:silence", T.panelAlt}})
    page.add({kind = "footer"})
    return page.items
end

------------------------------------------------------------
-- DRAWING
------------------------------------------------------------
local function drawNav(target, y, w, item)
    local win = target.win
    fill(win, 1, y, w, T.panel)
    local x = 2
    if item.back then
        local label = w >= 45 and " < Back " or " < "
        text(win, 1, y, label, T.text, T.panelAlt)
        table.insert(target.buttons, {x1 = 1, x2 = #label, y = y, action = "nav:overview"})
        x = #label + 2
    end
    local right = w - #item.buttons * 4 + 1
    if item.tag then
        text(win, x, y, item.tag, item.tagColor, T.panel)
        x = x + #item.tag + 1
    end
    text(win, x, y, item.title:sub(1, math.max(0, right - x - 1)), T.text, T.panel)
    for i, b in ipairs(item.buttons) do
        local bx = right + (i - 1) * 4
        text(win, bx, y, " " .. b[1] .. " ", onColor(b[3]), b[3])
        table.insert(target.buttons, {x1 = bx, x2 = bx + 2, y = y, action = b[2]})
    end
end

local function drawTopbar(win, y, w, item)
    fill(win, 1, y, w, T.panelAlt)
    text(win, 1, y, "[i]", T.info, T.panelAlt)
    text(win, 4, y, " Overview", T.text, T.panelAlt)
    if w >= 50 then centered(win, y, "REACTOR MANAGER", T.dim, T.panelAlt, w) end
    text(win, w - #item.value, y, item.value, T.energy, T.panelAlt)
end

local function drawSetting(target, y, w, item)
    local win = target.win
    -- Label, optional default hint, value, then the two 3-wide buttons.
    local valueX = w - 8 - #item.value
    local hint = item.changed and item.default and w >= 44 and ("def " .. item.default) or nil
    local labelRoom = valueX - 2 - 1 - (hint and #hint + 1 or 0)
    text(win, 2, y, item.label:sub(1, math.max(0, labelRoom)), T.text)
    if hint and labelRoom >= #item.label then
        text(win, valueX - 1 - #hint, y, hint, T.dim)
    end
    text(win, valueX, y, item.value, item.changed and T.accent or T.info)
    text(win, w - 7, y, " - ", T.text, T.panelAlt)
    text(win, w - 3, y, " + ", T.text, T.panelAlt)
    table.insert(target.buttons, {x1 = w - 7, x2 = w - 5, y = y, action = "set:" .. item.key .. ":-1"})
    table.insert(target.buttons, {x1 = w - 3, x2 = w - 1, y = y, action = "set:" .. item.key .. ":1"})
end

-- Footer row: optional pager, then the first alarm (tap to silence) or
-- the last logged event.
local function drawFooter(target, y, w, item, model)
    local win = target.win
    local ctl = model.controller
    local x = 1
    if item.pager then
        local p = item.pager
        local mid = string.format(" %d/%d ", p.page, p.pages)
        text(win, x, y, " < ", T.text, T.panelAlt)
        table.insert(target.buttons, {x1 = x, x2 = x + 2, y = y, action = "ovr:prev"})
        text(win, x + 3, y, mid, T.dim, T.bg)
        local nx = x + 3 + #mid
        text(win, nx, y, " > ", T.text, T.panelAlt)
        table.insert(target.buttons, {x1 = nx, x2 = nx + 2, y = y, action = "ovr:next"})
        x = nx + 4
    end
    local width = w - x + 1
    if width < 3 then return end
    local list = item.alarms or (ctl and ctl.alarms) or {}
    local alarm = list[1]
    if alarm then
        local msg = "! " .. alarm
        if #list > 1 then msg = msg .. string.format(" (+%d)", #list - 1) end
        fill(win, x, y, width, T.danger)
        text(win, x + math.max(0, math.floor((width - #msg) / 2)), y, msg:sub(1, width), T.bright, T.danger)
        -- Tapping the alarm bar silences repeating alarm sounds.
        table.insert(target.buttons, {x1 = x, x2 = w, y = y, action = "alarm:silence"})
    elseif model.events and model.events[1] then
        text(win, x + 1, y, model.events[1].message:sub(1, width - 2), T.dim)
    end
end

local function drawItems(target, items, model)
    local win = target.win
    local w = win.getSize()
    for y, item in ipairs(items) do
        if item.kind == "lr" then
            pair(win, 1, y, w, item.label, item.value, item.labelColor, item.color)
            if item.note and #item.label + #item.note + #item.value + 4 <= w then
                text(win, 3 + #item.label, y, item.note, T.dim)
            end
        elseif item.kind == "bar" then
            barAt(win, 2, y, w - 2, item.pct, item.color, item.marker)
        elseif item.kind == "buttons" then
            buttonRow(target, y, w, item.defs, item.widths, item.blank)
        elseif item.kind == "nav" then
            drawNav(target, y, w, item)
        elseif item.kind == "topbar" then
            drawTopbar(win, y, w, item)
        elseif item.kind == "cards" then
            for c, card in pairs(item.cards) do
                drawCardLine(target, 2 + (c - 1) * (item.cw + 1), y, item.cw, card, item.line, item.lines)
            end
        elseif item.kind == "setting" then
            drawSetting(target, y, w, item)
        elseif item.kind == "graph" then
            drawGraphRow(win, 2, y, item)
        elseif item.kind == "axis" then
            text(win, 2, y, item.left, T.dim)
            text(win, w - #item.right, y, item.right, T.dim)
        elseif item.kind == "footer" then
            drawFooter(target, y, w, item, model)
        end
        if item.action then
            table.insert(target.buttons, {x1 = 1, x2 = w, y = y, action = item.action})
        end
    end
end

------------------------------------------------------------
-- RENDER AND NAVIGATION
------------------------------------------------------------
local views = {}               -- monitor name -> {page, unit, overviewPage}

local function findUnit(units, id)
    for _, m in ipairs(units) do
        if m.id == id then return m end
    end
end

--[[
view = {
  units   = every unit model (unit.model()), including storage,
  core    = energy core reading shown on Draconic pages, or nil,
  events  = stat_utils.recent,
  pins    = monitor name -> unit id,
  formatSetting = persist.format
}
Each monitor keeps its own page: overview, or a unit's detail /
settings / graphs page. A pinned monitor stays on its unit.
]]
local function pageFor(name, view)
    local units = view.units or {}
    local v = views[name] or {page = "overview"}
    views[name] = v
    local pinned = view.pins and view.pins[name]
    if pinned and findUnit(units, pinned) then
        v.unit = pinned
        if v.page == "overview" then v.page = "detail" end
    else
        pinned = nil
    end
    if v.page ~= "overview" and v.page ~= "system" and not findUnit(units, v.unit) then
        v.page = "overview"
    end
    if #units == 1 and v.page == "overview" and not v.chosenOverview then
        v.page, v.unit = "detail", units[1].id
    end
    return v, pinned
end

local function renderTarget(target, view)
    local win = target.win
    local w, h = win.getSize()
    win.setBackgroundColor(T.bg)
    win.clear()
    target.buttons = {}
    local units = view.units or {}
    if #units == 0 then
        text(win, 2, 2, "No reactor connected", T.warn)
        return
    end
    if w < MIN_WIDTH or h < MIN_HEIGHT then
        text(win, 1, 1, "Screen too small", T.danger)
        text(win, 1, 2, string.format("Need %dx%d", MIN_WIDTH, MIN_HEIGHT), T.text)
        return
    end

    local v, pinned = pageFor(target.name, view)
    target.view = v
    if v.page == "system" then
        drawItems(target, pinFooter(fitLayout(buildSystem(view, w, h), h), h) or {}, {events = view.events})
        return
    end
    if v.page == "overview" then
        drawItems(target, pinFooter(fitLayout(buildOverview(units, w, h, v), h), h) or {}, {events = view.events})
        return
    end

    local model = {}
    for k, val in pairs(findUnit(units, v.unit)) do model[k] = val end
    model.core, model.events = view.core, view.events
    model.hourly = view.hourlyFor and view.hourlyFor(model.id) or nil
    model.formatSetting = view.formatSetting or function(_, val) return tostring(val) end
    model.nav = {back = not pinned, pinned = pinned ~= nil, page = v.page}
    if v.page == "settings" and not (model.settings and #model.settings > 0) then v.page = "detail" end

    local items
    if v.page == "settings" then
        items = buildSettings(model, w)
    elseif v.page == "graphs" then
        items = buildGraphs(model, w, h)
    else
        model.nav.page = "detail"
        items = buildLayout(model, w)
    end
    items = fitLayout(items, h)
    if items and v.page == "detail" then items = addTrends(items, model, w, h) end
    items = pinFooter(items, h)
    if not items then
        text(win, 1, 1, "Screen too small", T.danger)
        return
    end
    drawItems(target, items, model)
end

function monitor_utils.render(view)
    for _, name in ipairs(order) do
        local target = targets[name]
        local ok, err = target == nil, nil
        if not ok then ok, err = pcall(function()
            target.win.setVisible(false)
            renderTarget(target, view)
            target.win.setVisible(true)
        end) end
        if not ok then
            -- A detached monitor is re-initialised by the peripheral event;
            -- anything else is a bug, shown on the screen and reported once
            -- through lastError rather than silently freezing the display.
            monitor_utils.lastError = tostring(err)
            pcall(function()
                target.win.setVisible(true)
                target.win.setBackgroundColor(T.bg)
                target.win.clear()
                text(target.win, 1, 1, "Display error:", T.danger)
                text(target.win, 1, 2, tostring(err):sub(1, 200), T.text)
            end)
        end
    end
end

-- Handles a touch on display `name`. Navigation is handled here and
-- returns "redraw"; anything else returns action, unit id, display name
-- for the caller to apply. Returns nil when nothing was hit.
function monitor_utils.handleTouch(name, x, y)
    local target = targets[name]
    if not target then return nil end
    local v = views[name] or {page = "overview"}
    views[name] = v
    for _, b in ipairs(target.buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then
            local a = b.action
            local unitId = a:match("^nav:detail:(.+)$")
            if unitId then
                v.page, v.unit = "detail", unitId
            elseif a == "nav:overview" then
                v.page = "overview"
                v.chosenOverview = true
            elseif a == "nav:system" then
                v.page = "system"
            elseif a == "nav:detail" or a == "nav:graphs" or a == "nav:settings" then
                v.page = a:sub(5)
            elseif a == "ovr:next" then
                v.overviewPage = (v.overviewPage or 1) + 1
            elseif a == "ovr:prev" then
                v.overviewPage = math.max(1, (v.overviewPage or 1) - 1)
            elseif a == "noop" then
                return nil
            else
                return a, v.unit, name
            end
            return "redraw"
        end
    end
    return nil
end

-- Which page a display shows (for tests and diagnostics).
function monitor_utils.viewOf(name)
    return views[name]
end

monitor_utils.TERMINAL = TERMINAL
return monitor_utils
