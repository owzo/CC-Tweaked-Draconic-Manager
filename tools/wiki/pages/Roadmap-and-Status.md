# Roadmap and status

**Current version: v{{VERSION}}** (shown on the in-game System page; the
`CHECK` / `UPDATE` buttons there install newer versions).

## Status at a glance

| Area | State | Verified by |
| --- | --- | --- |
| Draconic Evolution reactors (charge, field and temperature control, trips, auto-restart, manual output) | Implemented | Automated tests against a reactor simulator that follows DE 1.12 and DE 1.16+ rules; CraftOS-PC end-to-end run |
| Extreme Reactors / Bigger Reactors (passive and steam reactors, turbines, steam groups, waste ejection) | Implemented | Simulator tests for both mods' APIs; CraftOS-PC run (Bigger Reactors) |
| Mekanism (fission protection and burn governor, fusion injection, turbines, boilers) | Implemented | Simulator tests; CraftOS-PC run including a coolant-loss SCRAM |
| Energy storage (DE energy core, Mekanism matrix and cubes, Flux Networks, Powah, Forge Energy blocks, energy meters) and the Energy Network page | Implemented | Adapter tests per API; CraftOS-PC run (energy core) |
| Touchscreen UI: overview, unit pages, graphs, settings, System page, `obsidian` theme | Implemented | Unit tests; CraftOS-PC rendering and touch checks ([results](docs/ui/craftos/results.txt)) |
| Alarms (speaker, chat box, redstone), long-term energy totals, in-game updater | Implemented | Unit tests |
| Remote logging to a PC collector | Implemented | Lua and Python tests |
| **Running in Minecraft with the real mods** | **Not yet verified** | Needs players: see below |

> [!WARNING]
> Nothing has run in Minecraft with the real reactor blocks yet. The
> simulators follow each mod's source and documentation, but real
> behaviour, server tick timing and rendering can differ. Test in a
> creative or test world first.

## How it is tested

- **Unit and simulation tests** (`tests/run_tests.lua`, run on Lua 5.2 and
  5.4 in CI, every file also parsed by Lua 5.1): a ComputerCraft mock plus
  simulators for each mod drive `main_control.lua` through start-up, trips,
  hot-plug, restarts, alarms, menus and updates.
- **CraftOS-PC end-to-end run** (`tools/craftos/run_scenario.sh`): the
  unchanged program on ComputerCraft 1.116.1 in the
  [CraftOS-PC](https://www.craftos-pc.cc) emulator by JackMacWindows,
  with real monitors and touch, driven like a player. 29 checks. This run
  found a real bug (a `monitor_resize` loop at text scale 0.5), which is
  fixed and covered by a regression test.
- **Collector tests** (`tools/test_log_collector.py`).

## Release history

| Version / PR | What it added |
| --- | --- |
| [#6](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/6) | Working reactor controller, DE 1.16+ physics, CC / DE compatibility fixes |
| [#7](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/7) | Works without `require` (os.loadAPI / old startup files) |
| [#8](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/8) | drmon-style dashboard |
| [#9](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/9)–[#11](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/11) | Several reactors at once, Extreme / Bigger Reactors, menus, settings, graphs |
| [#12](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/12) | Tuning, CI, steam groups, hot-plug, resume from shutdown, remembered manual modes, wiring checks |
| [#13](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/13) | Alarms, reactor waste and fuel handling, in-game updater, long-term totals |
| [#16](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/16) | Mekanism |
| [#14](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/14) | Logs to a PC (collector) |
| [#15](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/15) | Energy storage add-on and Energy Network |
| [#18](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/18) (v4.2) | `obsidian` theme from a Google Stitch design, teletext charts, walkthrough, CraftOS-PC testing, resize-loop fix |
| [#19](https://github.com/owzo/CC-Tweaked-Draconic-Manager/pull/19) | Credits |

## Roadmap

These are candidates, in rough priority order, not commitments.

1. **In-game verification**, one mod at a time: Draconic Evolution
   (1.20, DE 3.1.2.604+), Bigger Reactors, Extreme Reactors, Mekanism
   10.4. Report results (or problems) in the issue tracker with the mod
   versions and `logs/draconic.log`.
2. **Fix whatever in-game testing finds**, starting with real API
   differences from the simulators (method names, units, error messages).
3. **Mekanism control beyond fission**: turbine dumping-mode control and
   boiler protection (today they are monitored with alarms only).
4. **More storage mods** as players report their peripheral types.
5. **More themes**, for example a high-contrast / colour-blind palette.

## Helping

- Run it in a test world and open an issue with what worked and what did
  not (mod versions, monitor size, `logs/draconic.log`).
- Try the UI without Minecraft in CraftOS-PC: see
  [Development and testing](Development-and-Testing).
