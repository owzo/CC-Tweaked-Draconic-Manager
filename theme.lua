--==============================================================
-- DISPLAY THEMES (16-colour palettes)
-- Save as: theme.lua
--==============================================================

--[[
README
-------
CC:Tweaked monitors have 16 colour slots and setPaletteColour can give
each slot any RGB value. A theme assigns a role (background, panel,
ok, danger, energy, ...) to every slot and recolours the slots, so the
whole dashboard is drawn with role names instead of mod colours.

  theme.roles(name)      -> role -> colours constant used by the UI
  theme.apply(dev, name) recolour one monitor/terminal (no-op for
                         "classic" or devices without palette support)
  theme.restore(dev)     put the default CC palette back

Themes:
  "obsidian"  dark violet control-room palette designed in Google Stitch
              (docs/ui/stitch_prompt.md); the default
  "classic"   the stock CC palette, nothing is recoloured

The palette is restored when the program exits, so other programs on
the same monitors are not left with odd colours.
]]

local theme = {}

-- Role -> colours slot. Slot names are chosen so un-themed code still
-- reads sensibly (colors.red stays red, colors.green stays green).
local SLOTS = {
    bg = "black",          panel = "brown",      panelAlt = "gray",
    border = "pink",       text = "white",       dim = "lightGray",
    ok = "green",          warn = "yellow",      danger = "red",
    info = "lightBlue",    accent = "purple",    energy = "orange",
    heat = "magenta",      coolant = "cyan",     field = "blue",
    bright = "lime"
}

-- Stock-palette fallback: the closest default colour for every role.
local CLASSIC = {
    bg = "black",          panel = "black",      panelAlt = "gray",
    border = "gray",       text = "white",       dim = "lightGray",
    ok = "green",          warn = "orange",      danger = "red",
    info = "lightBlue",    accent = "purple",    energy = "lime",
    heat = "red",          coolant = "cyan",     field = "blue",
    bright = "white"
}

theme.PALETTES = {
    obsidian = {
        bg = 0x0f0d14,     panel = 0x1b1822,     panelAlt = 0x262232,
        border = 0x3d364f, text = 0xe4e1eb,      dim = 0x878196,
        ok = 0x34d399,     warn = 0xfbbf24,      danger = 0xef4444,
        info = 0x38bdf8,   accent = 0xa855f7,    energy = 0xf97316,
        heat = 0xf43f5e,   coolant = 0x06b6d4,   field = 0x818cf8,
        bright = 0xffffff
    }
}

theme.DEFAULT = "obsidian"

local function resolve(name)
    if name == "classic" then return nil end
    return theme.PALETTES[name or theme.DEFAULT] or theme.PALETTES[theme.DEFAULT]
end

function theme.roles(name)
    local map = resolve(name) and SLOTS or CLASSIC
    local out = {}
    for role, slot in pairs(map) do out[role] = colors[slot] end
    return out
end

local function setter(dev)
    return dev and (dev.setPaletteColour or dev.setPaletteColor)
end

function theme.apply(dev, name)
    local palette = resolve(name)
    local set = setter(dev)
    if not palette or not set then return false end
    for role, rgb in pairs(palette) do
        pcall(set, colors[SLOTS[role]], rgb)
    end
    return true
end

function theme.restore(dev)
    local set = setter(dev)
    local native = term and (term.nativePaletteColour or term.nativePaletteColor)
    if not set or not native then return end
    for _, slot in pairs(SLOTS) do
        local c = colors[slot]
        local ok, r, g, b = pcall(native, c)
        if ok and r then pcall(set, c, r, g, b) end
    end
end

return theme
