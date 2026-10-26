#!/usr/bin/env bash
# Runs tools/craftos/scenario.lua in CraftOS-PC on a virtual X display,
# takes screenshots of the emulated monitors when the scenario asks, and
# prints the results. Development only.
#
#   tools/craftos/run_scenario.sh <craftos-pc build dir> <rom dir> [out dir]
#
# Needs: a CraftOS-PC build (by JackMacWindows, MIT:
# https://github.com/MCJack123/craftos2), its
# ROM (https://github.com/MCJack123/craftos2-rom), Xvfb, xdotool and
# ImageMagick (import). Monitors (on the computer's top and left sides,
# as ComputerCraft lists only sides and wired-modem peripherals) are sized
# like a 3x3 advanced monitor:
# top at text scale 0.5 (56x38: CraftOS-PC sizes monitors in whole scale-1
# characters, so 57x38 is not reachable), left at scale 1 (29x19).
set -euo pipefail

CRAFTOS_DIR=$(cd "$1" && pwd)
ROM_DIR=$(cd "$2" && pwd)
OUT_DIR=${3:-docs/ui/craftos}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
DATA=$(mktemp -d)
COMPUTER="$DATA/computer/0"
DISPLAY_NUM=:97
mkdir -p "$OUT_DIR"

Xvfb "$DISPLAY_NUM" -screen 0 1920x1200x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill "$XVFB_PID" 2>/dev/null || true; rm -rf "$DATA"' EXIT
sleep 2
export DISPLAY=$DISPLAY_NUM

# The binary looks for its Lua library relative to the build directory.
(cd "$CRAFTOS_DIR" && timeout 1800 ./craftos --rom "$ROM_DIR" -d "$DATA" \
    --mount-ro "/repo=$REPO" \
    --exec "shell.run('/repo/tools/craftos/scenario.lua')" >"$DATA/stdout.txt" 2>&1) &
CRAFTOS_PID=$!

window_id() {
    xdotool search --name "Monitor $1\$" 2>/dev/null | head -n 1 || true
}

# SDL windows read back black through "import -window" on Xvfb, so the
# screenshot is cropped from the whole screen (windows are moved apart).
capture() {
    local X Y WIDTH HEIGHT SCREEN WINDOW
    eval "$(xdotool getwindowgeometry --shell "$1")"
    import -window root -crop "${WIDTH}x${HEIGHT}+${X}+${Y}" +repage "$2"
}

# Monitor windows snap to whole characters (12x18 px at CraftOS-PC's 2x
# zoom and text scale 1, one fewer than the request): 352x364 -> 28x19,
# too narrow for the dashboard, so it switches to scale 0.5 (56x38);
# 364x364 -> 29x19.
resized=0
while kill -0 "$CRAFTOS_PID" 2>/dev/null; do
    if [ "$resized" = 0 ]; then
        big=$(window_id top); small=$(window_id left)
        if [ -n "$big" ] && [ -n "$small" ]; then
            xdotool windowmove "$big" 0 0
            xdotool windowmove "$small" 400 0
            xdotool windowsize "$big" 352 364
            xdotool windowsize "$small" 364 364
            sleep 1
            mkdir -p "$COMPUTER" && touch "$COMPUTER/ready"
            resized=1
        fi
    fi
    if [ -f "$COMPUTER/snap_request" ]; then
        name=$(cat "$COMPUTER/snap_request")
        sleep 0.5
        capture "$(window_id top)" "$OUT_DIR/${name}.png"
        if [ "$name" = "cpc_small" ]; then
            capture "$(window_id left)" "$OUT_DIR/${name}_29x19.png"
        fi
        echo "screenshot: $OUT_DIR/${name}.png"
        rm -f "$COMPUTER/snap_request"
    fi
    sleep 0.3
done

if [ -f "$COMPUTER/results.txt" ]; then
    cat "$COMPUTER/results.txt"
    cp "$COMPUTER/results.txt" "$OUT_DIR/results.txt"
    [ -f "$COMPUTER/logs/draconic.log" ] && cp "$COMPUTER/logs/draconic.log" "$OUT_DIR/draconic.log"
    grep -q " 0 failed" "$COMPUTER/results.txt"
else
    echo "no results; CraftOS-PC output:" >&2
    tail -c 2000 "$DATA/stdout.txt" >&2
    exit 1
fi
