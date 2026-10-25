# CC:Tweaked-Draconic Manager

A ComputerCraft: Tweaked program that runs a Draconic Evolution reactor:
it charges and starts the reactor, holds the containment field and core
temperature at their targets, trips to a controlled shutdown on unsafe
conditions, and shows everything on a touchscreen dashboard.

## Features

- **Field regulation**: input gate set to `fieldDrainRate / (1 - targetField)`, which holds the field at 50% by default.
- **Temperature regulation**: a cascade controller holds the core at `targetTemperature` (7000 °C by default). The outer loop picks an energy-saturation setpoint and the inner loop holds it. This matters on DE 1.16+, where below about 10% saturation the core gains hundreds of degrees per tick.
- **Manual output mode** with ±1k / 10k / 100k buttons. Increases ramp in slowly, and an interlock switches back to AUTO when heat climbs.
- **Trips**: when a limit is crossed the reactor gets a controlled stop. The containment field stays fed until the reactor is cold. The limits are:
  - temperature above `maxTemperature` (8000 °C)
  - field below `minField` (20%)
  - remaining fuel below `minFuel` (10%)
- **Auto-restart**: after a temperature or field trip the reactor restarts once it has cooled below `safeTemperature`. This is capped at 3 restarts per hour, after which a person has to press START. A low-fuel trip never restarts on its own.
- **Fail-safe exit**: if the program stops (Ctrl+T, crash, reactor link lost), the output gate goes to 0 and the input gate to twice the last field demand. With output at 0, saturation climbs and field drain collapses, so that margin is wide.
- **Plug-and-play detection**: peripherals are found by the methods they expose, not by their names. On DE 1.16 to 1.20 flux gates report the type `flow_gate`, not `flux_gate`. This breaks drmon and was one cause of [issue 5](https://github.com/owzo/CC-Tweaked-Draconic-Manager/issues/5). Detection works with any modem name. If two gates are found you are asked once which one is the input, and the answer is saved.
- **Dashboard** (styled after drmon): shows status, generation, temperature, field, saturation, fuel, gate rates, an optional energy core readout and alarms. It redraws through a buffer, so there is no flicker. It works on any number of monitors and falls back to the computer screen when none are attached.
- **Logging**: events go to `logs/draconic.log` and a stats CSV to `logs/reactor_stats.csv`. Both rotate in size so the disk can never fill up.

## Requirements

- Minecraft with **Draconic Evolution** and **CC:Tweaked**
- A fully built reactor (core, 4 stabilizers, 1+ injector) fuelled with **awakened** draconium (1–8 blocks)
- Two **flux gates**:
  - **input gate**: energy source → gate → reactor **energy injector**
  - **output gate**: reactor **stabilizer** → gate → your storage (energy core)
- An **Advanced Computer**
- Optional: advanced monitors (3x3 recommended) and an energy core pylon

### Wiring (read this first)

```text
  [Computer]--wired modem
                  |  networking cable
                  +--wired modem--[Reactor Stabilizer]
                  +--wired modem--[Input Flux Gate]   (feeds Energy Injector)
                  +--wired modem--[Output Flux Gate]  (fed by a Stabilizer)
                  +--wired modem--[Monitor]           (optional)
                  +--wired modem--[Energy Pylon]      (optional)
```

- Use **wired** modems and networking cable. *Wireless and ender modems
  cannot attach peripherals.* Earlier versions of this README said to use
  wireless modems, and that is why "input flux gate not found" happened ([issue 5](https://github.com/owzo/CC-Tweaked-Draconic-Manager/issues/5)).
- **Right-click every wired modem** after placing it. The ring turns red and
  chat prints `Peripheral "flow_gate_0" connected to network`. A modem that
  hasn't been right-clicked is invisible to the computer.
- Instead of a modem you can place a peripheral directly against the computer.
- Run `peripherals` in the computer shell to see what it can reach.

## Installation

```shell
wget https://raw.githubusercontent.com/owzo/CC-Tweaked-Draconic-Manager/main/install.lua install.lua
install
```

The installer downloads every file before writing any of them, so a failed
download changes nothing. It keeps an existing `config.lua` and creates
`startup.lua`, so the manager restarts after reboots and chunk reloads.
Running `install` again updates the program.

### Offline (HTTP API disabled)

1. Put all `.lua` files from this repository on a floppy disk. In single
   player you can copy them into
   `saves/<world>/computercraft/disk/<disk id>/`.
2. Insert the disk into a disk drive next to the computer.
3. Run `disk/offline_install`.
4. Remove the disk, then run `main_control` (or reboot).

## First run

1. Run `main_control`.
2. If it lists two flux gates, enter the number of the gate that feeds the
   **energy injector**. This is saved. To change it later:
   `set draconic.inputGate flow_gate_1` and `set draconic.outputGate flow_gate_0`.
3. Press **START** on the monitor. The manager charges the reactor, activates
   it when warm-up is complete, then regulates it.

A reactor that is already running when the program starts keeps running. A
cold reactor is only charged after START, unless `autoStartOnBoot = true`.

## Controls

| Button | Action |
| --- | --- |
| `<<<` `<<` `<` / `>` `>>` `>>>` (under Output Gate) | Output −/+ 100k, 10k, 1k RF/t (switches to manual) |
| `AU` / `MA` (middle of that row) | Toggle automatic temperature regulation (green = auto, orange = manual) |
| `START` | Charge + activate; clears a latched trip |
| `STOP` | Controlled shutdown (field stays fed until cold) |

The layout follows [drmon](https://github.com/acidjazz/drmon)'s look:
- label on the left, value on the right
- full RF/t figures with separators
- colour-coded bars
- blank rows between sections
- the last action, or an active alarm, on the bottom line

The layout fits itself to the monitor: on a 3x3 it drops spacer rows first,
and larger monitors get more breathing room.

In manual mode, output increases ramp in at 1% of generation per cycle. An
interlock switches back to AUTO when the temperature passes a quarter of the
way from the target to the trip limit, or when it rises faster than 100 °C/s
above the target.

## Configuration (`config.lua`)

| Key | Default | Meaning |
| --- | --- | --- |
| `peripherals.*` | `nil` | Force a peripheral name instead of auto-detecting |
| `reactor.targetTemperature` | 7000 | Regulated core temperature (°C) |
| `reactor.targetField` | 0.50 | Regulated field strength |
| `reactor.maxTemperature` | 8000 | Trip above this |
| `reactor.minField` | 0.20 | Trip below this |
| `reactor.minFuel` | 0.10 | Trip when remaining fuel is below this |
| `reactor.safeTemperature` | 3000 | Auto-restart only below this |
| `reactor.autoRestart` | true | Restart after temperature/field trips |
| `reactor.chargeInflow` | 2,000,000 | Input during warm-up (RF/t) |
| `reactor.maxInflow` | 100,000,000 | Input cap, also used for field emergencies |
| `reactor.maxOutflow` | 1,000,000,000 | Output cap (the regulator sets the real rate) |
| `reactor.outputAggressiveness` | 1.0 | Temperature loop gain multiplier |
| `reactor.controlInterval` | 0.05 | Seconds per control cycle (1 game tick) |
| `ui.textScale` | auto | Monitor text scale |
| `logging.statsInterval` | 10 | Seconds between CSV rows |

The program checks the config at startup and refuses to run with
inconsistent limits (for example a target above the trip temperature).

## Compatibility (CC:Tweaked ↔ Draconic Evolution)

These were checked against both mods' source (DE `1.20` branch, CC:Tweaked
`mc-1.20.x`) and their issue trackers.

| Topic | What to know |
| --- | --- |
| **DE version (1.20.1)** | DE builds before August 2024 shipped broken CC integration ([DE PR 1817](https://github.com/brandon3055/Draconic-Evolution/pull/1817), [CC issue 1897](https://github.com/cc-tweaked/CC-Tweaked/issues/1897)). Gates, stabilizers and pylons only show up as CC's generic `energy_storage`, which can't control anything. **Use DE 3.1.2.604 or newer**; older modpacks such as early ATM9 are affected. The program detects this and tells you. |
| **Gate type name** | On DE 1.16–1.20 both flux and fluid gates report `flow_gate`. Detection is by method, so this works, but **a fluid gate looks identical to a flux gate**. If one shares the network, set `inputGate` / `outputGate` in `config.lua`. |
| **Which blocks are peripherals** | Reactor **stabilizers and injectors** (type `draconic_reactor`), **flow gates** and the **energy pylon** (`draconic_rf_storage`). The reactor core block and the energy core block are *not* peripherals. Modems attach on any face. |
| **Generic peripherals** | CC prefers a block's own peripheral over its generic ones, so DE methods are never mixed with `energy_storage`. Other mods' energy blocks can't be mistaken for the energy core. |
| **Call cost** | Every DE method runs on the server thread and takes about one tick. The program writes both gates in the same tick, skips writes that wouldn't change anything, and measures its real cycle time (`cycle_s` in the stats CSV). It warns above 0.25 s. |
| **Reactor not loaded** | `getReactorInfo()` returns nothing when the core's chunk is unloaded or the component is unbound. The program treats that as "blind": output 0 and input at twice the last field demand. |
| **Command results** | `chargeReactor` / `activateReactor` / `stopReactor` return `true` even when the reactor refuses. The program confirms every command by re-reading the status. |
| **Gate memory** | A gate's override and rate are saved with the world. If the computer stops, the gate keeps its last value, so chunk-load everything and keep `startup.lua`. |
| **Fail-safe** | DE 1.16+ only has `toggleFailSafe()` (not `setFailSafe`), and it doesn't protect against field loss. This program doesn't use it. |

## How the reactor works (DE 1.16 to 1.20, from the mod source)

- **It only explodes when the containment field reaches 0 while the core
  is above 2000 °C.** No temperature by itself triggers it. Very high
  temperature makes the field drain grow with the square of the overshoot
  above 8000 °C, roughly 3.5x at 9000 °C.
- **Generation** is `(1 − saturation) × base × (1 + 2 × conversion)`. Output
  rises steeply as fuel converts: an 8-block core at 8000 °C makes about 53M
  RF/t on fresh fuel and about 256M RF/t at 80% conversion (default
  `reactorOutputMultiplier`). DE 1.12 numbers are 1/100 of that.
- **Field input** gains `input × (1 − field%)`, and the injector wastes any
  excess. Holding 50% field costs 2x the drain, holding 25% costs 1.33x.
- **Stopping** still drains the field. The stabilizers stop outputting,
  saturation climbs, and the core cools only once saturation passes 99%.
  This program keeps the field fed until the core is `cooling`.
- **Calls cost a tick on 1.20**: every CC call into the reactor or a gate
  runs on the server thread. The gate adapter skips writes when the rate
  hasn't changed.

## Pushing it to the edge

Settings that fit the mechanics, from conservative to aggressive:

| Setting | Default (safe) | Edge |
| --- | --- | --- |
| `targetTemperature` | 7000 | 7900 |
| `maxTemperature` | 8000 | 8200 |
| `targetField` | 0.50 | 0.25 |
| `minField` | 0.20 | 0.12 |
| `minFuel` | 0.10 | 0.10 (never go past ~90% conversion) |

- **Most of the gain comes from temperature and fuel conversion, not the
  field.** Going from 50% to 25% field adds only a few percent of net output
  once conversion is high.
- **Don't run hotter than 8000 °C.** Going to 9000 °C adds about 10%
  generation but about 4x the field drain, a net loss with less margin.
- **A low field target costs reaction time.** By my calculation from the
  source formulas (not measured in game), a full 1.20 core at 8000 °C drains
  about 12% of its maximum field per tick when input stops. At 25%
  field you have about 2 ticks, at 50% about 4. That's why the program
  runs every tick and fails safe whenever it can't see the reactor.
- **Refuel at about 90% conversion.** Near 100% the core cannot cool down
  even at full saturation.
- **Laggy servers** shrink every margin. Keep the default settings there.

The edge settings are covered by a simulator test (`[DE 1.20] edge
tuning`). The simulator is not the game, so step toward them gradually and
watch `logs/reactor_stats.csv`.

## Operational notes

- **Your energy source has to be able to supply `maxInflow`.** If the core
  that feeds the injector runs dry, nothing can hold the field.
- **Keep the computer, the reactor and both gates chunk-loaded.** If the
  chunk unloads, the program stops while the gates hold their last setting.
  This is the most common cause of explosions.
- The input gate must feed an **energy injector**, and the output gate must
  take power from a **stabilizer**.
- A full energy core is safe. The reactor can't output, so saturation rises
  and the temperature falls.

## Troubleshooting

| Error | Cause and fix |
| --- | --- |
| `Failed to load API reac_utils` / `attempt to call global 'require' (a nil value)` | Old version that used `os.loadAPI`, where APIs run without `require` ([issue 3](https://github.com/owzo/CC-Tweaked-Draconic-Manager/issues/3)). Run the installer again. Current modules never call `require`, and `main_control` falls back to loading files directly if it is started without the shell. |
| `No reactor found` / `Need two flux gates` | Check the wiring (wired modems, right-clicked). The message lists every peripheral the computer can see; compare it with `peripherals`. |
| Only `energy_storage` peripherals listed | Draconic Evolution build too old for CC. Update to 3.1.2.604+ (see Compatibility). |
| `Control loop runs every …s` warning | Server lag. Keep conservative limits. |

## Development

```text
main_control.lua       entry point: loops, input dispatch, fail-safe exit
reac_utils.lua         discovery, gate adapter, controller (pure logic)
monitor_utils.lua      dashboard rendering and touch hit-testing
energy_core_utils.lua  optional energy pylon readout
stat_utils.lua         event log, stats CSV, rotation
config.lua             user settings
install.lua            online installer
offline_install.lua    floppy-disk installer
tests/                 CC mock, reactor simulator, test suite
```

Run the tests with any Lua 5.2+ interpreter from the repository root:

```shell
lua tests/run_tests.lua
```

The suite has controller unit tests and closed-loop runs against an
approximate reactor model (`tests/reactor_sim.lua`). The model is transcribed
from DE's `TileReactorCore`, with both the 1.12 and 1.16+ rule sets. There is
also an end-to-end run of `main_control.lua` under a virtual-time CC:Tweaked
mock.
The simulator is only an approximation. Test new settings on a reactor you
can afford to lose.

## Disclaimer

Use at your own risk. The simulator is no substitute for in-game testing,
and reactor explosions are permanent.

## License

MIT. See [LICENSE](LICENSE).
