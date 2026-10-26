# Accessibility

The manager is used on in-game ComputerCraft monitors, often from a
distance, in moments that matter (a reactor overheating). The aim is that
everyone can read its state quickly and act on it.

## What it does today

- **Status is never colour alone.** Every state has a word (`RUNNING`,
  `SCRAMMED`, `NO SIGNAL`...), alarms have a text line (`! SCRAM: coolant
  13% < 20%`), and numbers are always printed next to bars.
- **High-contrast default theme.** The `obsidian` palette uses light text
  on a near-black background, and alarm text is white on red.
- **A stock-colour fallback.** `config.ui.theme = "classic"` keeps
  ComputerCraft's default palette, for players whose resource packs or
  shaders already adjust colours, or who prefer it.
- **Large touch targets.** Buttons are at least three characters wide with
  gaps between them; START / STOP get taller on bigger monitors.
- **Adjustable text size.** The layout fits itself to any monitor from
  29x15 characters. By default the text scale is chosen automatically (1,
  or 0.5 on small monitors); set `config.ui.textScale` (0.5 to 5) for
  larger text on a big monitor. Fewer characters then fit, and the layout
  drops spacing first.
- **Alarms beyond the screen.** Speakers, chat-box messages and redstone
  outputs can announce alarms to players who aren't looking at the monitor
  (`config.alarms`).
- **Logs off the game.** Remote logging writes every event to plain text
  files on a real computer, readable with a screen reader or any tool.

## Known limitations

- ComputerCraft monitors have one fixed pixel font. Text size depends only
  on monitor size and text scale (0.5 to 5); there is no font choice.
- Monitors have 16 colours and no other visual cues. Bars, charts and
  status colours are visual; their values are in text, but charts have no
  text alternative beyond their current value and range.
- In-game screens can't be read by screen readers. The log files and the
  remote collector are the accessible alternative.
- The UI hasn't been tested with colour-blindness simulators or in
  Minecraft itself yet (see the
  [roadmap](https://github.com/owzo/CC-Tweaked-Draconic-Manager/wiki/Roadmap-and-Status)).
  A dedicated colour-blind-safe theme is on the roadmap.

## Reporting a barrier

If something is hard to read, reach or understand, please open an
[issue](https://github.com/owzo/CC-Tweaked-Draconic-Manager/issues/new/choose).
Describe what you were trying to do and your monitor size, and mention
any colour vision, resource pack or shader setup. Accessibility problems
are treated as bugs.
