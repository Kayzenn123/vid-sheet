#!/usr/bin/env bash
# Tests for vid-sheet.sh — run: bash test.sh
# Generates small synthetic fixtures with ffmpeg lavfi (no network, no
# copyrighted media) and exercises the CLI as a real process.
set -uo pipefail
cd "$(dirname "$0")"

BIN="./vid-sheet.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'ok %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }
check() { # check NAME CONDITION...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

# --- fixtures: 10s 320x240 and 6s 640x360 synthetic videos ------------------
ffmpeg -v error -f lavfi -i testsrc2=duration=10:size=320x240:rate=30 \
  -c:v libx264 -pix_fmt yuv420p -y "$TMP/fixture10.mp4" \
  || { echo "cannot build fixture10" >&2; exit 1; }
ffmpeg -v error -f lavfi -i testsrc2=duration=6:size=640x360:rate=30 \
  -c:v libx264 -pix_fmt yuv420p -y "$TMP/fixture6.mp4" \
  || { echo "cannot build fixture6" >&2; exit 1; }
printf 'hello, not a video\n' > "$TMP/notvideo.txt"

dims() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 -- "$1"; }

# --- help / version / usage errors ------------------------------------------
"$BIN" --help >/dev/null 2>&1
[ $? -eq 0 ] && "$BIN" --help 2>&1 | grep -q "Usage:" && ok "help exits 0 and shows Usage" || bad "help exits 0 and shows Usage"

V="$("$BIN" --version 2>&1)"
[ $? -eq 0 ] && [ "$V" = "vid-sheet 1.0.0" ] && ok "version prints vid-sheet 1.0.0" || bad "version prints vid-sheet 1.0.0"

"$BIN" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no args exits 2" || bad "no args exits 2"
"$BIN" --bogus "$TMP/fixture10.mp4" >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown flag exits 2" || bad "unknown flag exits 2"
"$BIN" --frames 0 "$TMP/fixture10.mp4" >/dev/null 2>&1; [ $? -eq 2 ] && ok "--frames 0 exits 2" || bad "--frames 0 exits 2"
"$BIN" --every 0 "$TMP/fixture10.mp4" >/dev/null 2>&1; [ $? -eq 2 ] && ok "--every 0 exits 2" || bad "--every 0 exits 2"
"$BIN" --format gif "$TMP/fixture10.mp4" >/dev/null 2>&1; [ $? -eq 2 ] && ok "--format gif exits 2" || bad "--format gif exits 2"

# --- runtime errors ----------------------------------------------------------
"$BIN" "$TMP/nope.mp4" >/dev/null 2>&1; [ $? -eq 1 ] && ok "missing file exits 1" || bad "missing file exits 1"
"$BIN" "$TMP/notvideo.txt" >/dev/null 2>&1; [ $? -eq 1 ] && ok "non-video input exits 1" || bad "non-video input exits 1"

# --- basic run: 12 frames, 4 cols, 320px tiles -> 1280x720 -------------------
"$BIN" --quiet "$TMP/fixture10.mp4" >/dev/null 2>&1
[ $? -eq 0 ] && [ -f "$TMP/fixture10.sheet.jpg" ] && [ "$(dims "$TMP/fixture10.sheet.jpg")" = "1280,720" ] \
  && ok "default run creates 1280x720 sheet" || bad "default run creates 1280x720 sheet"

# --- grid options -------------------------------------------------------------
"$BIN" --quiet --frames 4 --cols 2 --output "$TMP/grid4.jpg" "$TMP/fixture10.mp4" >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(dims "$TMP/grid4.jpg")" = "640,480" ] \
  && ok "--frames 4 --cols 2 gives 640x480" || bad "--frames 4 --cols 2 gives 640x480"

# --- --every mode: 10s video, every 3s -> 3 frames, 1 row --------------------
"$BIN" --quiet --every 3 --output "$TMP/every3.jpg" "$TMP/fixture10.mp4" >/dev/null 2>&1
[ $? -eq 0 ] && [ "$(dims "$TMP/every3.jpg")" = "1280,240" ] \
  && ok "--every 3 gives 3 frames in one row" || bad "--every 3 gives 3 frames in one row"

# --- png format ----------------------------------------------------------------
"$BIN" --quiet --format png --frames 2 --cols 2 --output "$TMP/two.png" "$TMP/fixture10.mp4" >/dev/null 2>&1
[ $? -eq 0 ] && [ -f "$TMP/two.png" ] && [ "$(dims "$TMP/two.png")" = "640,240" ] \
  && ok "--format png creates a valid 640x240 png" || bad "--format png creates a valid 640x240 png"

# --- --no-timestamps still renders -------------------------------------------
"$BIN" --quiet --no-timestamps --frames 2 --output "$TMP/nots.jpg" "$TMP/fixture10.mp4" >/dev/null 2>&1
[ $? -eq 0 ] && [ -f "$TMP/nots.jpg" ] && ok "--no-timestamps renders" || bad "--no-timestamps renders"

# --- --json: valid JSON with 12 timestamps -------------------------------------
J="$("$BIN" --quiet --json --output "$TMP/j.jpg" "$TMP/fixture10.mp4" 2>/dev/null)"
echo "$J" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['frames']==12 and len(d['timestamps'])==12 and d['columns']==4 and d['rows']==3, d" \
  && ok "--json is valid with 12 timestamps" || bad "--json is valid with 12 timestamps"

# --- --list: 12 timestamps, first 00:00:00, last 00:00:09, no file ------------
L="$("$BIN" --quiet --list --output "$TMP/should-not-exist.jpg" "$TMP/fixture10.mp4" 2>/dev/null)"
[ "$(printf '%s\n' "$L" | wc -l)" = "12" ] && [ "$(printf '%s' "$L" | head -1)" = "00:00:00" ] \
  && [ "$(printf '%s' "$L" | tail -1)" = "00:00:09" ] && [ ! -f "$TMP/should-not-exist.jpg" ] \
  && ok "--list prints 12 timestamps and renders nothing" || bad "--list prints 12 timestamps and renders nothing"

# --- --list --json --------------------------------------------------------------
LJ="$("$BIN" --quiet --list --json "$TMP/fixture10.mp4" 2>/dev/null)"
echo "$LJ" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['timestamps'][0]=='00:00:00' and d['timestamps'][-1]=='00:00:09', d" \
  && ok "--list --json gives timestamp JSON" || bad "--list --json gives timestamp JSON"

# --- batch: two videos, two sheets ---------------------------------------------
"$BIN" --quiet "$TMP/fixture10.mp4" "$TMP/fixture6.mp4" >/dev/null 2>&1
[ $? -eq 0 ] && [ -f "$TMP/fixture10.sheet.jpg" ] && [ -f "$TMP/fixture6.sheet.jpg" ] \
  && [ "$(dims "$TMP/fixture6.sheet.jpg")" = "1280,540" ] \
  && ok "batch of two videos creates two sheets" || bad "batch of two videos creates two sheets"

# --- --output with two inputs is a usage error ----------------------------------
"$BIN" --output "$TMP/x.jpg" "$TMP/fixture10.mp4" "$TMP/fixture6.mp4" >/dev/null 2>&1
[ $? -eq 2 ] && ok "--output with two inputs exits 2" || bad "--output with two inputs exits 2"

# --- ffmpeg missing: exit 1 with a clear message -------------------------------
mkdir -p "$TMP/emptybin"
MSG="$(env -i PATH="$TMP/emptybin" /bin/bash "$BIN" "$TMP/fixture10.mp4" 2>&1)"
[ $? -eq 1 ] && printf '%s' "$MSG" | grep -q "ffmpeg not found" \
  && ok "missing ffmpeg exits 1 with clear message" || bad "missing ffmpeg exits 1 with clear message"

# --- human output line names the created file -----------------------------------
OUT="$("$BIN" --frames 2 --output "$TMP/human.jpg" "$TMP/fixture10.mp4" 2>/dev/null)"
printf '%s' "$OUT" | grep -q "created $TMP/human.jpg (2 frames, 4x1 grid" \
  && ok "human output names file, frames and grid" || bad "human output names file, frames and grid"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
