"""Render the simulated monitor screens in docs/ui/ (development only).

Usage, from the repository root (needs Pillow and lupa):

    python3 tools/screenshots/render.py [output_dir]

Runs tools/screenshots/scenes.lua in Lua 5.2 (lupa), which drives
main_control.lua against simulated reactors, then draws every dumped
screen as a PNG with the palette the program set, including
ComputerCraft's 2x3-dot teletext characters (128-159) and the
checkerboard character (127). Text is drawn with DejaVu Sans Mono, not
the Minecraft font, so the in-game look differs slightly.
"""

import os
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

# CC:Tweaked default palette, used for slots the program did not change.
DEFAULT_PALETTE = {
    1: "f0f0f0", 2: "f2b233", 4: "e57fd8", 8: "99b2f2", 16: "dede6c",
    32: "7fcc19", 64: "f2b2cc", 128: "4c4c4c", 256: "999999", 512: "4c99b2",
    1024: "b266e5", 2048: "3366cc", 4096: "7f664c", 8192: "57a64e",
    16384: "cc4c4c", 32768: "111111",
}
CELL_W, CELL_H = 12, 18
MARGIN = 8
FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/Library/Fonts/Menlo.ttc",
    "C:/Windows/Fonts/consola.ttf",
]


def load_font():
    """Return the first available monospace font, or Pillow's default."""
    for path in FONT_PATHS:
        if os.path.exists(path):
            return ImageFont.truetype(path, 15)
    return ImageFont.load_default()


def run_scenes(dump_path):
    """Run scenes.lua under Lua 5.2, writing the screen dump file."""
    from lupa import lua52  # imported here so --help works without lupa

    runtime = lua52.LuaRuntime()
    runtime.globals().arg_out = dump_path
    runtime.execute("dofile(...)", "tools/screenshots/scenes.lua")


def draw_cell(draw, x0, y0, char, fg, bg):
    """Draw one character cell, handling teletext and checkerboard."""
    draw.rectangle([x0, y0, x0 + CELL_W - 1, y0 + CELL_H - 1], fill=bg)
    if 128 <= char <= 159:
        bits = char - 128
        dot_w, dot_h = CELL_W // 2, CELL_H // 3
        for k in range(5):
            if bits & (1 << k):
                sx, sy = k % 2, k // 2
                draw.rectangle([x0 + sx * dot_w, y0 + sy * dot_h,
                                x0 + sx * dot_w + dot_w - 1,
                                y0 + sy * dot_h + dot_h - 1], fill=fg)
    elif char == 127:
        for sy in range(0, CELL_H, 3):
            for sx in range((sy // 3) % 2 * 3, CELL_W, 6):
                draw.rectangle([x0 + sx, y0 + sy, x0 + sx + 2, y0 + sy + 2],
                               fill=fg)
    elif char != 32:
        draw.text((x0 + 1, y0 + 1), chr(char), font=FONT, fill=fg)


def render(dump_path, out_dir):
    """Convert every screen in the dump into <out_dir>/<name>.png."""
    with open(dump_path, encoding="latin1") as handle:
        lines = handle.read().splitlines()
    written, i = [], 0
    while i < len(lines):
        parts = lines[i].split(" ")
        name, width, height = parts[1], int(parts[2]), int(parts[3])
        palette = dict(DEFAULT_PALETTE)
        if len(parts) > 4 and parts[4]:
            for pair in parts[4].split(";"):
                slot, rgb = pair.split("=")
                palette[int(slot)] = rgb

        def colour(slot):
            return "#" + palette.get(slot, "111111")

        image = Image.new("RGB", (width * CELL_W + 2 * MARGIN,
                                  height * CELL_H + 2 * MARGIN), "#000000")
        draw = ImageDraw.Draw(image)
        for y in range(height):
            for x, cell in enumerate(lines[i + 1 + y].split(" ")):
                char, fg, bg = (int(v) for v in cell.split(","))
                draw_cell(draw, MARGIN + x * CELL_W, MARGIN + y * CELL_H,
                          char, colour(fg), colour(bg))
        path = os.path.join(out_dir, name + ".png")
        image.save(path, optimize=True)
        written.append(path)
        i += 1 + height
    return written


FONT = load_font()

if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "docs/ui"
    os.makedirs(target, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        dump_file = os.path.join(tmp, "screens.txt")
        run_scenes(dump_file)
        for written_path in render(dump_file, target):
            print(written_path)
