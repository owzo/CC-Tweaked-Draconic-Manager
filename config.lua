--==============================================================
-- CONFIGURATION FILE
-- Save as: config.lua
--==============================================================

--[[
README
-------
Central configuration for the CC:Tweaked Draconic Reactor Manager.

Every value below has a safe default. You normally only need to touch
the PERIPHERALS section if auto-detection cannot work out your setup
(for example when you have more than one reactor on the same network).

All percentages are expressed as fractions (0.50 = 50%).
All rates are RF/t. All temperatures are degrees Celsius.
]]

local config = {}

------------------------------------------------------------
-- PERIPHERALS
------------------------------------------------------------
-- Leave a value as nil to auto-detect it.
--
-- Peripherals are detected by the methods they expose, not by their
-- names, so this works across Draconic Evolution versions
-- (1.12 "flux_gate", 1.16+ "flow_gate", etc).
--
-- Names are what `peripherals` prints in the CC shell, e.g.
-- "flow_gate_0", "draconic_reactor_1", "left", "back".
--
-- IMPORTANT: peripherals must be reached through WIRED modems and
-- networking cable (or be directly adjacent to the computer).
-- Wireless/ender modems cannot attach peripherals.
config.peripherals = {
    reactor    = nil,   -- Reactor stabilizer (or injector) modem
    inputGate  = nil,   -- Flux gate feeding the reactor ENERGY INJECTOR
    outputGate = nil,   -- Flux gate taking power FROM a reactor STABILIZER
    energyCore = nil,   -- Primary energy store (optional, display only)
    monitors   = {}     -- Empty = use every attached monitor
}

------------------------------------------------------------
-- REACTOR SAFETY AND REGULATION
------------------------------------------------------------
config.reactor = {
    -- Operating targets
    targetTemperature = 7000.0,     -- Output is regulated to hold this
    targetField       = 0.50,       -- Input is regulated to hold this

    -- Trip limits (reactor is stopped immediately when crossed)
    maxTemperature    = 8000.0,     -- Stop above this temperature
    minField          = 0.20,       -- Stop below this containment field
    minFuel           = 0.10,       -- Stop when remaining fuel < 10%

    -- Restart behaviour
    safeTemperature   = 3000.0,     -- Auto-restart only once cooled below
    autoRestart       = true,       -- Restart after temperature/field trips
    autoStartOnBoot   = false,      -- Charge a cold reactor when program starts

    -- Flux gate limits. DE 1.16+ reactors generate ~100x more than 1.12
    -- (50-250M RF/t for a full core), so the caps are deliberately high;
    -- the regulator, not the cap, decides the real rates.
    chargeInflow      = 2000000,    -- Input rate while charging/warming up
    maxInflow         = 100000000,  -- Input cap (used for field emergencies)
    maxOutflow        = 1000000000, -- Output cap (lower it to protect cables)

    -- Output regulation tuning (1.0 = default; lower = gentler)
    outputAggressiveness = 1.0,

    -- Controller cycle time in seconds (0.05 = every game tick). On DE
    -- 1.20 each peripheral call already takes a tick, so cycles may run
    -- slower than this; they are never faster.
    controlInterval   = 0.05
}

------------------------------------------------------------
-- EXTREME REACTORS / BIGGER REACTORS (optional)
------------------------------------------------------------
-- Used only when either mod's Computer Ports are on the network. Both
-- mods are found automatically; neither can melt down, so these tune
-- efficiency, not safety.
config.extreme = {
    -- Reactor rods keep a buffer between these fractions: the reactor's
    -- own FE battery (passively cooled) or its steam tank (actively
    -- cooled; the band's middle is the target).
    bufferLow       = 0.30,
    bufferHigh      = 0.70,
    lowFuel         = 0.10,         -- Alarm below this fuel fraction
    wasteEjectAt    = 0.20,         -- Eject waste above this share of the
                                    -- fuel tank (needs an access port set
                                    -- to output); nil = never
    wasteAlarmAt    = 0.50,         -- Alarm when waste still piles up

    -- Turbines: efficiency peaks at ~1800 RPM in both mods.
    targetRPM       = 1800,
    maxRPM          = 2000,         -- Steam is cut above this
    coilsOffAbove   = 0.95,         -- Turbine buffer full: coils off
    coilsOnBelow    = 0.80,         -- ...and back on below this

    autoStartOnBoot = false,        -- Activate reactors/turbines on start
    controlInterval = 0.25,         -- Seconds per control cycle

    -- Control loop speed multipliers (1.0 = tested default). Lower one if
    -- rods or steam flow keep hunting back and forth; raise it if the
    -- buffer or RPM drifts and recovers slowly. Also on the S page.
    rodGain         = 1.0,
    flowGain        = 1.0,

    -- Optional names and per-unit overrides, by peripheral name:
    -- units = {{peripheral = "BigReactors-Turbine_0", name = "Turbine A",
    --           settings = {targetRPM = 900}}},
    units = {}
}

------------------------------------------------------------
-- ENERGY STORAGE (optional, display only)
------------------------------------------------------------
-- Energy stores on the network are found automatically: Draconic energy
-- core pylons, Mekanism induction matrices and energy cubes, Flux
-- Networks controllers (UnlimitedPeripheralWorks), Powah cells, Advanced
-- Peripherals energy detectors, and any block CC:Tweaked shows as
-- "energy_storage" (EnderIO capacitor banks, Thermal cells, ...).
-- Names below are peripheral names; "*" matches anything
-- ("mekanism*", "enderio:*_capacitor_bank_*").
config.storage = {
    enabled = true,
    include = {},                   -- Non-empty: use ONLY these peripherals
    exclude = {},                   -- Never use these
    names   = {},                   -- e.g. {inductionPort_0 = "Main Matrix"}
    pollInterval = 1                -- Seconds between readings
}

------------------------------------------------------------
-- MEKANISM (optional)
------------------------------------------------------------
-- Fission reactors CAN melt down (damage above 1200 K, explosion at
-- 100% damage). These limits SCRAM well before that; a tripped reactor
-- stays off until a person presses START.
config.mekanism = {
    targetBurnRate   = nil,         -- mB/t; nil = keep the reactor's current rate
    burnRampPerSecond = 1.0,        -- Max burn-rate increase per second
    maxTemperature   = 1000,        -- K: SCRAM at or above (damage starts at 1200)
    tempMargin       = 100,         -- K below maxTemperature where burn is cut back
    maxDamage        = 0,           -- %: SCRAM on any damage
    minCoolant       = 0.20,        -- SCRAM when coolant tank below this
    maxHeatedCoolant = 0.95,        -- SCRAM when steam/heated coolant backs up
    maxWaste         = 0.90,        -- SCRAM when waste tank above this
    lowFuel          = 0.05,        -- Alarm below this fuel fraction
    scramOnExit      = true,        -- SCRAM fission reactors when the program stops
    autoStartOnBoot  = false,
    fusionInjection  = nil,         -- Even number 2-98; nil = leave as set in game
    controlInterval  = 0.5,         -- Seconds per cycle (each read costs a tick)
    -- Optional names/overrides by peripheral name:
    -- units = {{peripheral = "fissionReactorPort_0", name = "Fission A"}},
    units = {}
}

------------------------------------------------------------
-- ALARMS
------------------------------------------------------------
-- Every unit alarm (trip, low fuel, link lost, charging stalled,
-- overspeed, waste...) can sound, post to chat and drive redstone.
config.alarms = {
    enabled            = true,
    speaker            = true,      -- Any attached speaker plays a bell
    repeatSeconds      = 10,        -- Repeat while active (tap the red
                                    -- alarm bar to silence)
    chat               = true,      -- Advanced Peripherals Chat Box
    chatPrefix         = "Reactor",
    redstoneSide       = nil,       -- e.g. "top": on while any alarm
    redstoneIntegrator = nil        -- AP Redstone Integrator name, to use
                                    -- its side instead of the computer's
}

------------------------------------------------------------
-- UPDATES
------------------------------------------------------------
config.update = {
    -- Where the System page checks for and installs new versions.
    repoBase = "https://raw.githubusercontent.com/owzo/CC-Tweaked-Draconic-Manager/main/"
}

------------------------------------------------------------
-- USER INTERFACE
------------------------------------------------------------
config.ui = {
    textScale       = nil,          -- nil = choose automatically
    refreshInterval = 0.5,          -- Seconds between screen redraws
    manualStep      = {1000, 10000, 100000}, -- Output button increments
    graphInterval   = 5,            -- Seconds between graph samples

    -- Dedicate monitors to one unit each (by unit name or id). Monitors
    -- not listed show the overview. "PIN HERE" on a unit's settings page
    -- does the same from in game and is remembered.
    -- monitorUnits = {monitor_1 = "Alpha", monitor_2 = "Turbine 1"},
    monitorUnits    = {}
}

------------------------------------------------------------
-- LOGGING AND STATISTICS
------------------------------------------------------------
-- Every log line and stats row is written under `directory`. On the
-- host disk that is <world>/computercraft/computer/<id>/logs/ (see the
-- README section "Logs on a real computer").
config.logging = {
    directory     = "logs",         -- Created automatically
    maxFileBytes  = 65536,          -- Rotate files beyond this size
    statsInterval = 10,             -- Seconds between stats CSV rows
    printLevel    = "WARN",         -- Minimum level echoed to terminal

    -- Optional: also send every log line and CSV row to
    -- tools/log_collector.py running on a real computer. LAN/localhost
    -- collectors must be allowed in computercraft-server.toml first.
    remote = {
        enabled      = false,
        url          = "http://192.168.1.50:8780/ingest",
        token        = "",          -- Same value as the collector's --token
        batchSeconds = 5,           -- Seconds between batches
        maxQueue     = 1000,        -- Lines kept while the collector is down
        timeout      = 10           -- Seconds per HTTP request
    }
}

return config
