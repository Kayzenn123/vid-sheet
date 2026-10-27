# vid-sheet

> Build a timestamped contact sheet (thumbnail grid) from any video, with ffmpeg only. Daily Tools #21.

## Why

Previewing a video means scrubbing through it. A contact sheet — one image
with evenly spaced frames — shows the whole video at a glance: check takes,
pick a thumbnail, or archive a visual summary without pressing play.

The closest alternatives found on GitHub are `thomas-berrio/video-thumbnail-grid-generator`
(Bash, but needs ImageMagick, has no timestamp labels, no JSON output, and
only fixed 3x3/4x4/5x5 grids), `abdusco/thumber` (a compiled Go binary you
must install, no JSON or dry-run mode), and `evanthemann/ffmpeg-contact-sheet`
(fixed 5x5 grid, interactive only, no flags at all). vid-sheet is a single
Bash file with no install step and no ImageMagick: ffmpeg is the only
dependency. Every tile is labelled with its timestamp, `--json` gives a
machine-readable summary, `--list` previews the planned timestamps before
rendering, the frame count and column count are free, `--every` handles long
videos by time interval, and several videos can be processed in one run.

## Install

```bash
git clone https://github.com/Kayzenn123/vid-sheet.git
cd vid-sheet
chmod +x vid-sheet.sh
# no dependencies to install besides ffmpeg
```

Requires: ffmpeg + ffprobe (any recent version), Bash 4+. Fully offline.
A TrueType font is needed for timestamp labels — DejaVu Sans is found
automatically on most Linux systems; set `VID_SHEET_FONT=/path/to/font.ttf`
to pick another one. Without a font, labels are skipped with a warning.

## Usage

```bash
./vid-sheet.sh [options] <video> [video ...]
./vid-sheet.sh --frames 6 --cols 3 --width 480 demo.mp4
./vid-sheet.sh --every 30 long.mp4
./vid-sheet.sh --list --frames 8 clip.mp4
./vid-sheet.sh --json a.mp4 b.mp4
```

| Flag | Function | Default |
| --- | --- | --- |
| `--frames N` | frames to extract | 12 |
| `--cols C` | grid columns | 4 |
| `--width W` | width of each tile in pixels | 320 |
| `--every S` | one frame every S seconds (replaces `--frames`) | — |
| `--format F` | output format: `jpg` or `png` | `jpg` |
| `--quality Q` | JPEG quality 1–100 (ignored for png) | 85 |
| `--output FILE` | output file (single input only) | `<stem>.sheet.jpg` next to the input |
| `--timestamps` / `--no-timestamps` | burn `HH:MM:SS` on each tile | on |
| `--list` | print planned timestamps, do not render (dry-run) | off |
| `--json` | print a machine-readable summary as JSON | off |
| `--quiet` | print only errors | off |
| `--help`, `--version` | show help / version | — |

Exit codes: 0 success, 1 runtime error (missing file, not a video, ffmpeg
missing), 2 bad usage. Info goes to stderr, results to stdout. Output is
plain text (no colours), so `NO_COLOR` is respected trivially.

## Example output

Command:

```bash
./vid-sheet.sh examples/demo.mp4
```

Output (real, copied from an actual run):

```text
created examples/demo.sheet.jpg (12 frames, 4x3 grid, 1280,540)
```

The sheet is a 1280x540 image: 12 tiles of 320x135, each labelled with its
timestamp. A 45-second video with default settings:

```bash
./vid-sheet.sh runs/fixtures/talk-45s.mp4
```

```text
created runs/fixtures/talk-45s.sheet.jpg (12 frames, 4x3 grid, 1280,540)
```

JSON summary for two videos at once (`--json --frames 6 --cols 3 --width 240`):

```bash
./vid-sheet.sh --json --frames 6 --cols 3 --width 240 runs/fixtures/vertical-20s.mp4 runs/fixtures/talk-45s.mp4
```

```text
{"input": "runs/fixtures/vertical-20s.mp4", "output": "runs/fixtures/vertical-20s.sheet.jpg", "format": "jpg", "duration": 20.000000, "frames": 6, "columns": 3, "rows": 2, "tile_width": 240, "dimensions": "720,854", "timestamps": ["00:00:01", "00:00:05", "00:00:08", "00:00:11", "00:00:15", "00:00:18"]}
{"input": "runs/fixtures/talk-45s.mp4", "output": "runs/fixtures/talk-45s.sheet.jpg", "format": "jpg", "duration": 45.000000, "frames": 6, "columns": 3, "rows": 2, "tile_width": 240, "dimensions": "720,270", "timestamps": ["00:00:03", "00:00:11", "00:00:18", "00:00:26", "00:00:33", "00:00:41"]}
```

Dry-run first, render later (a 10-second clip, 8 frames):

```bash
./vid-sheet.sh --list --frames 8 clip.mp4
```

```text
00:00:00
00:00:01
00:00:03
00:00:04
00:00:05
00:00:06
00:00:08
00:00:09
```

## How it works

1. `ffprobe` reads the video duration.
2. Timestamps are computed in Bash: in `--frames` mode each frame sits at
   the centre of its segment (`t = duration * (i + 0.5) / N`), so the first
   frame is never the (often black) frame 0; in `--every` mode frames sit
   at `(k + 0.5) * interval` seconds.
3. For each timestamp, one `ffmpeg` call seeks to it, extracts the frame,
   scales it to the tile width, and burns the `HH:MM:SS` label with the
   `drawtext` filter (labelled after scaling, so the text stays legible).
4. The frames are tiled into one image with ffmpeg's `tile` filter.
5. In `--list` mode steps 3–4 are skipped and only the timestamps print.

Files: `vid-sheet.sh` (the whole tool, ~300 lines), `test.sh` (21 tests),
`examples/demo.mp4` (a 6-second synthetic clip made with ffmpeg `testsrc2`,
so you can try it immediately).

## Limitations

- Requires ffmpeg and ffprobe in `PATH`; without them it exits 1 with a
  clear message.
- Timestamp labels need a TrueType font. If none is found, the sheet is
  still built, just without labels (and a warning is printed).
- Frames are evenly spaced by time, not by scene change — a static stretch
  of video produces near-identical tiles. Scene-based selection is not in
  this version.
- Tiles keep the source aspect ratio, so mixed-orientation batches produce
  sheets of different heights per video (each sheet itself is uniform).
- Rotation metadata in the source video is not corrected.
- Very long videos with a small `--every` interval produce many frames and
  a very tall sheet; pick a larger interval or fewer frames.

## Development

```bash
bash test.sh
```

21 tests, green twice in a row. Tests generate their own synthetic fixtures
with ffmpeg `testsrc2` (no network, no copyrighted media) and cover help,
version, usage errors, missing ffmpeg, non-video input, grid geometry
(checked with ffprobe), `--json` validity, `--list` dry-run, `--every` mode,
png output, `--no-timestamps`, and batch processing.

## License

MIT

---
Ringkasan (Bahasa Indonesia): vid-sheet membuat contact sheet dari video —
satu gambar berisi grid thumbnail yang masing-masing berlabel jamnya,
pakai ffmpeg saja tanpa ImageMagick. Cara pakai: `./vid-sheet.sh video.mp4`,
atur jumlah frame, kolom, dan lebar tile lewat flag; ada mode `--every`
untuk video panjang, `--list` untuk cek dulu, dan `--json` untuk mesin.
Batasannya: butuh ffmpeg dan font TrueType untuk label, frame diambil
merata berdasarkan waktu (bukan scene), dan metadata rotasi video tidak
dikoreksi.
