# Google Stitch brief: Reactor Manager monitor UI

Paste **Prompt 1** into Stitch first to set the design system and the overview
screen. Then paste the **Prompt 2** follow-ups one at a time, in the same
project, so every screen shares the same style.

---

## Prompt 1: design system and overview screen

```text
Design a control-room dashboard for a power-plant manager that runs on a
Minecraft ComputerCraft monitor. The monitor is a TEXT GRID, not a pixel
screen, so treat these as hard rules, not style hints:

CANVAS
- The screen is 57 columns x 38 rows of character cells.
- Draw each cell 12 x 18 px, so the canvas is 684 x 684 px.
- Show a faint cell grid so the alignment can be checked.
- Every element must start and end exactly on cell boundaries.

TEXT
- One fixed monospace font in a single size. No bold, no italic, no
  other sizes.
- Each cell holds one character, and each character has one text colour
  and one background colour.
- Large text (headline numbers) may only be made from block characters,
  the way old teletext did it.

COLOUR
- Use exactly 16 colours for the whole app. Any RGB values are allowed,
  but there may be no more than 16.
- Only solid flat fills: no gradients, shadows, blur, transparency,
  rounded corners or anti-aliasing.
- At the end, output the palette as a table with three columns: slot
  number 0-15, role, hex.
- Name the roles: background, panel, panel-alt, border, text, text-dim,
  ok, warn, danger, info, accent, energy, heat, coolant, plus two spare.

SHAPES
- Panels and boxes are blocks of background colour, at least one cell
  each.
- Borders are a 1-cell-wide band of a different colour, or the box-drawing
  characters ─ │ ┌ ┐ └ ┘.
- Bars are horizontal runs of cells. Each cell is either full, or split
  into 2 halves left/right.
- Graphs use a sub-cell "pixel" grid of 2 wide by 3 tall per cell, so a
  graph 50 cells wide is 100 x (rows*3) dots. Inside a single cell only 2
  colours may appear.
- No images, icons, emoji or photos. Simple symbols built from characters
  are fine.

INTERACTION
- Input is a touch on one cell; there is no hover or scrolling.
- Buttons are at least 3 cells wide and 1 row tall.
- Keep a 1-cell gap between buttons.

SCREEN: OVERVIEW (the home page)
1. A 1-row header bar with three parts:
   - left: "[i] Overview"
   - centre: the app name "REACTOR MANAGER"
   - right: a clock "12:41"
2. A 2-row network summary:
   - total generation "1.24M FE/t"
   - total stored "68%", shown as a bar
   - net flow "+212k FE/t" in green
3. A grid of unit cards, two per row, each 27 x 7 cells. Each card shows:
   - name, e.g. "Draconic 1", with the mod as a small tag, e.g. "DE"
   - a status word in its status colour: RUNNING / WARMING / STOPPING /
     OFFLINE / SCRAMMED / NO SIGNAL
   - a power line, e.g. "640k FE/t"
   - one key gauge bar, e.g. "Temp 7,980C" or "Field 32%"
   - a one-line alarm area, shown in red when an alarm is active
   Show 6 cards using a mix of these unit types:
   - Draconic reactor
   - Extreme Reactors fission reactor
   - turbine
   - Mekanism fission reactor
   - energy storage
   - energy meter
4. A footer row of buttons:
   - "< Prev"
   - "Page 1/2"
   - "Next >"
   - an alarm area at the right edge that, when active, reads
     "! 2 ALARMS - TAP TO SILENCE" in white on red

Mood: industrial reactor control room, high-contrast and readable from a
distance, with the energy theme of Draconic Evolution (dark background,
deep purple and orange accents). Status colours must be clearly
distinguishable for colour-blind players: do not rely on hue alone, and
always show the status word too.
```

---

## Prompt 2: follow-up screens (one at a time, same project)

```text
Same design system and rules. New screen: DRACONIC REACTOR DETAIL, 57 x 38 cells.
- Header: "< Back", the title "Draconic 1", and the buttons "G" (graphs),
  "S" (settings) and "X" (close).
- A big status word in block characters: "RUNNING".
- Label/value rows:
  - Generation 640k RF/t
  - Temperature 7,980 C (heat colour; bar towards 8,000 limit)
  - Field Strength 32% (bar; target marker at 30%)
  - Energy Saturation 41% (bar)
  - Fuel Conversion 12% (bar)
  - Output Gate 655k RF/t
  - Input Gate 21k RF/t
- One row of output controls, buttons: <<< << < AU > >> >>>
  (AU = auto mode, green; shown as MA in orange when manual).
- START and STOP buttons (green and red) at the bottom.
- Alarm footer as on the overview.
```

```text
Same design system. New screen: GRAPHS for one unit, 57 x 38 cells.
- Header as before, with the title "Draconic 1 - Graphs".
- Top chart: "Energy per hour, last 24 h", drawn as a bar chart on the 2x3
  sub-cell dot grid.
- Below it, two line charts side by side:
  - "Temperature, last 10 min"
  - "Field strength, last 10 min"
- Each chart has a min/max label in text-dim and a current-value label in
  its series colour.
- Footer with the buttons "1h", "24h" and "48h".
```

```text
Same design system. New screen: SETTINGS for one unit, 57 x 38 cells.
- Header as before, with the title "Draconic 1 - Settings".
- A vertical list of settings, one per row, each row showing:
  label (left) | current value (right-aligned) | buttons "-" and "+"
- Rows:
  - Target Temp 8,000C
  - Max Temp 8,200C
  - Target Field 30%
  - Min Field 15%
  - Restart At 3,000C
  - Output Gain 1.0
  - Auto Restart ON
- Changed values are highlighted in the accent colour.
- A "Reset to defaults" button at the bottom in the danger colour.
```

```text
Same design system. New screen: SYSTEM page, 57 x 38 cells.
- Header with "< Back" and the title "System".
- Version row: "v4.1", a right-aligned button "Check for update", and a
  status line "v4.2 available - tap UPDATE twice".
- "Lifetime energy 4.21T FE".
- A 24-hour network energy bar chart.
- An active alarm list: one alarm per row, with time, unit and message.
- A remote log status row: "Log shipping: OK, 0 queued".
```

```text
Same design system, COMPACT variant: redesign the OVERVIEW for a small
monitor of 29 x 19 cells (cells still 12 x 18 px, canvas 348 x 342 px).
- One card per row, 2-3 rows tall each.
- Keep the header, the network line and the alarm footer.
```

---

## What to send back

1. A screenshot of every screen, exported at 1:1 so that 1 cell = 12x18 px.
2. The 16-colour palette table (slot, role, hex).
3. Optional: Stitch's HTML/CSS export. It helps me read exact colours and
   positions, but the screenshots are what I build from.

## Why the rules are so strict

| Constraint | What actually causes it |
|---|---|
| A grid of cells, one font | CC:Tweaked monitors only draw characters (`term.write`); there are no pixels or fonts. |
| 16 colours | Each monitor has 16 palette slots. `setPaletteColor` can make each slot any RGB, but 16 is the hard cap. |
| 2 colours per cell | A cell has one text colour and one background colour. The 2x3 "teletext" characters (128-159) give finer graphs, but within those same 2 colours. |
| Monitor sizes | At text scale 0.5: a 3x2 block monitor is 57x24, 3x3 is 57x38, and the maximum 8x6 is 164x81. At scale 1, 3x3 is 29x19. |
| Touch is per cell | The `monitor_touch` event reports the column and row of the touched cell, and nothing else. |

Anything Stitch produces outside these rules (gradients, icons, rounded
corners) will be approximated or dropped when ported. The tighter it
follows the grid, the closer the in-game result will look to the mock-up.
