#!/usr/bin/env bash
# vid-sheet — make a timestamped contact sheet (thumbnail grid) from a video.
# One video in, one image out: N evenly spaced frames, each labelled with
# its timestamp, tiled into a grid. Pure ffmpeg/ffprobe, no ImageMagick,
# no network, no other dependencies. Bash 4+, Linux/macOS/Termux.
#
# Usage: vid-sheet.sh [options] <video> [video ...]
# Exit codes: 0 success, 1 runtime error, 2 bad usage.
set -uo pipefail

VERSION="1.0.0"
PROG="vid-sheet"

FRAMES=12
COLS=4
WIDTH=320
EVERY=""
FORMAT="jpg"
QUALITY=85
OUTPUT=""
TIMESTAMPS=1
LIST_ONLY=0
JSON_OUT=0
QUIET=0

die() { printf '%s: error: %s\n' "$PROG" "$1" >&2; exit "${2:-1}"; }
info() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1" >&2; }
usage_error() { printf '%s: error: %s\n' "$PROG" "$1" >&2; printf 'Try %s --help for usage.\n' "$PROG" >&2; exit 2; }

print_help() {
  cat <<EOF
Usage: $PROG [options] <video> [video ...]

Build a contact sheet: a grid of timestamped thumbnails from a video,
using ffmpeg only (no ImageMagick, fully offline).

Options:
  --frames N        frames to extract (default 12)
  --cols C          grid columns (default 4)
  --width W         width of each tile in pixels (default 320)
  --every S         one frame every S seconds (replaces --frames)
  --format F        output format: jpg or png (default jpg)
  --quality Q       JPEG quality 1-100 (default 85; ignored for png)
  --output FILE     output file (single input only)
  --timestamps      burn HH:MM:SS on each tile (default)
  --no-timestamps   skip timestamp labels
  --list            print planned timestamps, do not render (dry-run)
  --json            print a machine-readable summary as JSON to stdout
  --quiet           print only errors
  --help            show this help
  --version         show version

Output: <input-stem>.sheet.jpg next to the input video, unless
--output is given. Existing output files are overwritten.
Timestamps need a TrueType font (VID_SHEET_FONT, fc-match, or a
DejaVu font in a standard location); without one, labels are skipped
with a warning.

Examples:
  $PROG talk.mp4
  $PROG --frames 6 --cols 3 --width 480 demo.mp4
  $PROG --every 30 --format png long.mp4
  $PROG --list --frames 8 clip.mp4
  $PROG --json a.mp4 b.mp4
EOF
}

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_num() { printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; }

# fmt_hms SECONDS -> HH:MM:SS (truncates to whole seconds)
fmt_hms() {
  awk -v s="$1" 'BEGIN { s=int(s); printf "%02d:%02d:%02d", s/3600, (s%3600)/60, s%60 }'
}

# find_font -> prints a TTF path, or nothing
find_font() {
  if [ -n "${VID_SHEET_FONT:-}" ] && [ -f "$VID_SHEET_FONT" ]; then
    printf '%s' "$VID_SHEET_FONT"; return 0
  fi
  if command -v fc-match >/dev/null 2>&1; then
    local f
    f="$(fc-match --format '%{file}' 'DejaVu Sans' 2>/dev/null || true)"
    if [ -n "$f" ] && [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  fi
  local p
  for p in /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
           /usr/share/fonts/TTF/DejaVuSans.ttf \
           /System/Library/Fonts/Supplemental/Arial.ttf \
           /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf; do
    if [ -f "$p" ]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# json_escape STR -> JSON string body (escapes backslash and quote)
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# --- argument parsing -------------------------------------------------------
INPUTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --help) print_help; exit 0 ;;
    --version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    --frames) [ $# -ge 2 ] || usage_error "--frames needs a value"
      is_int "$2" || usage_error "--frames needs a positive integer, got '$2'"
      [ "$2" -ge 1 ] || usage_error "--frames must be at least 1"
      FRAMES="$2"; shift 2 ;;
    --cols) [ $# -ge 2 ] || usage_error "--cols needs a value"
      is_int "$2" || usage_error "--cols needs a positive integer, got '$2'"
      [ "$2" -ge 1 ] || usage_error "--cols must be at least 1"
      COLS="$2"; shift 2 ;;
    --width) [ $# -ge 2 ] || usage_error "--width needs a value"
      is_int "$2" || usage_error "--width needs a positive integer, got '$2'"
      [ "$2" -ge 32 ] || usage_error "--width must be at least 32"
      WIDTH="$2"; shift 2 ;;
    --every) [ $# -ge 2 ] || usage_error "--every needs a value"
      is_num "$2" || usage_error "--every needs a number of seconds, got '$2'"
      EVERY="$2"; shift 2 ;;
    --format) [ $# -ge 2 ] || usage_error "--format needs a value"
      case "$2" in jpg|png) FORMAT="$2" ;; *) usage_error "--format must be jpg or png, got '$2'" ;; esac
      shift 2 ;;
    --quality) [ $# -ge 2 ] || usage_error "--quality needs a value"
      is_int "$2" || usage_error "--quality needs an integer 1-100, got '$2'"
      [ "$2" -ge 1 ] && [ "$2" -le 100 ] || usage_error "--quality must be 1-100"
      QUALITY="$2"; shift 2 ;;
    --output) [ $# -ge 2 ] || usage_error "--output needs a value"
      OUTPUT="$2"; shift 2 ;;
    --timestamps) TIMESTAMPS=1; shift ;;
    --no-timestamps) TIMESTAMPS=0; shift ;;
    --list) LIST_ONLY=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --) shift; while [ $# -gt 0 ]; do INPUTS+=("$1"); shift; done ;;
    -*) usage_error "unknown option: $1" ;;
    *) INPUTS+=("$1"); shift ;;
  esac
done

[ "${#INPUTS[@]}" -ge 1 ] || usage_error "no input video given"
if [ -n "$EVERY" ]; then
  awk -v e="$EVERY" 'BEGIN { exit (e > 0) ? 0 : 1 }' || usage_error "--every must be greater than 0"
fi
if [ -n "$OUTPUT" ] && [ "${#INPUTS[@]}" -gt 1 ]; then
  usage_error "--output works with a single input only"
fi

# --- dependency check -------------------------------------------------------
for cmd in ffmpeg ffprobe awk mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd not found in PATH (ffmpeg + ffprobe are required)"
done

FONT=""
if [ "$TIMESTAMPS" -eq 1 ]; then
  FONT="$(find_font || true)"
  if [ -z "$FONT" ]; then
    info "$PROG: warning: no TrueType font found, timestamp labels disabled"
    TIMESTAMPS=0
  fi
fi

# --- per-video work ---------------------------------------------------------
# build_sheet INPUT OUTPUT -> prints "N ROWS COLS" on success; exit 1 on failure
build_sheet() {
  local input="$1" output="$2"
  local duration nframes rows i t label esc_label
  local tmpdir frame

  [ -f "$input" ] || { printf '%s: error: file not found: %s\n' "$PROG" "$input" >&2; return 1; }
  duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$input" 2>/dev/null || true)"
  is_num "$duration" || { printf '%s: error: cannot read duration (not a video?): %s\n' "$PROG" "$input" >&2; return 1; }
  awk -v d="$duration" 'BEGIN { exit (d > 0) ? 0 : 1 }' || { printf '%s: error: zero-length video: %s\n' "$PROG" "$input" >&2; return 1; }

  # timestamps: evenly spaced, each at the centre of its segment
  local -a stamps=()
  if [ -n "$EVERY" ]; then
    i=0
    while :; do
      t="$(awk -v e="$EVERY" -v k="$i" 'BEGIN { printf "%.3f", (k + 0.5) * e }')"
      awk -v tt="$t" -v d="$duration" 'BEGIN { exit (tt < d) ? 0 : 1 }' || break
      stamps+=("$t"); i=$((i + 1))
    done
  else
    for ((i = 0; i < FRAMES; i++)); do
      stamps+=("$(awk -v d="$duration" -v n="$FRAMES" -v k="$i" 'BEGIN { printf "%.3f", d * (k + 0.5) / n }')")
    done
  fi
  nframes="${#stamps[@]}"
  [ "$nframes" -ge 1 ] || { printf '%s: error: no frame falls inside %s (video %.1fs, --every %ss?)\n' "$PROG" "$input" "$duration" "$EVERY" >&2; return 1; }
  rows=$(( (nframes + COLS - 1) / COLS ))

  if [ "$LIST_ONLY" -eq 1 ]; then
    for t in "${stamps[@]}"; do fmt_hms "$t"; printf '\n'; done
    return 0
  fi

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  i=0
  for t in "${stamps[@]}"; do
    i=$((i + 1))
    frame="$tmpdir/frame-$(printf '%03d' "$i").png"
    # Extract one frame, scaled to tile size first, then burn the label at
    # tile resolution (labelling before scaling would shrink the text).
    local vf="scale=${WIDTH}:-1"
    if [ "$TIMESTAMPS" -eq 1 ]; then
      label="$(fmt_hms "$t")"
      esc_label="${label//:/\\:}"
      local fontsize
      fontsize=$(( WIDTH / 18 )); [ "$fontsize" -lt 12 ] && fontsize=12
      vf="$vf,drawtext=fontfile='$FONT':text='$esc_label':fontcolor=white:fontsize=$fontsize:box=1:boxcolor=black@0.6:boxborderw=4:x=8:y=8"
    fi
    ffmpeg -v error -ss "$t" -i "$input" -frames:v 1 -vf "$vf" -y "$frame" \
      || { printf '%s: error: ffmpeg failed extracting frame at %ss from %s\n' "$PROG" "$t" "$input" >&2; return 1; }
    info "$PROG: frame $i/$nframes at $(fmt_hms "$t")"
  done

  local qv
  if [ "$FORMAT" = "jpg" ]; then
    qv=$(( (100 - QUALITY) * 29 / 99 + 2 ))
    ffmpeg -v error -framerate 1 -i "$tmpdir/frame-%03d.png" \
      -filter_complex "scale=${WIDTH}:-1,tile=${COLS}x${rows}" \
      -frames:v 1 -q:v "$qv" -y "$output" \
      || { printf '%s: error: ffmpeg failed tiling frames for %s\n' "$PROG" "$input" >&2; return 1; }
  else
    ffmpeg -v error -framerate 1 -i "$tmpdir/frame-%03d.png" \
      -filter_complex "scale=${WIDTH}:-1,tile=${COLS}x${rows}" \
      -frames:v 1 -y "$output" \
      || { printf '%s: error: ffmpeg failed tiling frames for %s\n' "$PROG" "$input" >&2; return 1; }
  fi
  [ -f "$output" ] || { printf '%s: error: output was not created: %s\n' "$PROG" "$output" >&2; return 1; }
  printf '%s %s %s' "$nframes" "$rows" "$duration"
}

FAILED=0
for input in "${INPUTS[@]}"; do
  dir="$(dirname -- "$input")"
  base="$(basename -- "$input")"
  stem="${base%.*}"; [ "$stem" = "$base" ] && stem="$base"
  if [ -n "$OUTPUT" ]; then out="$OUTPUT"; else out="$dir/$stem.sheet.$FORMAT"; fi

  if [ "$LIST_ONLY" -eq 1 ] && [ "$JSON_OUT" -eq 0 ]; then
    # --list without --json: plain timestamps, nothing else on stdout
    if ! build_sheet "$input" "$out"; then FAILED=1; fi
    continue
  fi

  # render (or list, when --json is also given)
  result="$(build_sheet "$input" "$out" 2>/tmp/vid-sheet-err.$$)" || { cat /tmp/vid-sheet-err.$$ >&2; rm -f /tmp/vid-sheet-err.$$; FAILED=1; continue; }
  rm -f /tmp/vid-sheet-err.$$
  if [ "$LIST_ONLY" -eq 1 ]; then
    # --list --json: result holds the timestamps printed by build_sheet
    # (stdout was captured); re-emit as JSON below using duration from probe
    duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$input")"
    ts_json=""
    first=1
    while IFS= read -r line; do
      [ "$first" -eq 1 ] && first=0 || ts_json="$ts_json, "
      ts_json="$ts_json\"$line\""
    done <<EOF
$result
EOF
    printf '{"input": "%s", "duration": %s, "timestamps": [%s]}\n' \
      "$(json_escape "$input")" "$duration" "$ts_json"
    continue
  fi

  nframes="$(printf '%s' "$result" | awk '{print $1}')"
  rows="$(printf '%s' "$result" | awk '{print $2}')"
  duration="$(printf '%s' "$result" | awk '{print $3}')"
  dims="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 -- "$out" 2>/dev/null || echo '?x?')"

  if [ "$JSON_OUT" -eq 1 ]; then
    # timestamps for JSON: recompute deterministically from duration
    ts_json=""
    first=1
    if [ -n "$EVERY" ]; then
      k=0
      while :; do
        t="$(awk -v e="$EVERY" -v kk="$k" 'BEGIN { printf "%.3f", (kk + 0.5) * e }')"
        awk -v tt="$t" -v d="$duration" 'BEGIN { exit (tt < d) ? 0 : 1 }' || break
        [ "$first" -eq 1 ] && first=0 || ts_json="$ts_json, "
        ts_json="$ts_json\"$(fmt_hms "$t")\""
        k=$((k + 1))
      done
    else
      for ((k = 0; k < nframes; k++)); do
        t="$(awk -v d="$duration" -v n="$nframes" -v kk="$k" 'BEGIN { printf "%.3f", d * (kk + 0.5) / n }')"
        [ "$first" -eq 1 ] && first=0 || ts_json="$ts_json, "
        ts_json="$ts_json\"$(fmt_hms "$t")\""
      done
    fi
    printf '{"input": "%s", "output": "%s", "format": "%s", "duration": %s, "frames": %s, "columns": %s, "rows": %s, "tile_width": %s, "dimensions": "%s", "timestamps": [%s]}\n' \
      "$(json_escape "$input")" "$(json_escape "$out")" "$FORMAT" "$duration" "$nframes" "$COLS" "$rows" "$WIDTH" "$dims" "$ts_json"
  else
    printf 'created %s (%s frames, %sx%s grid, %s)\n' "$out" "$nframes" "$COLS" "$rows" "$dims"
  fi
done

exit "$FAILED"
