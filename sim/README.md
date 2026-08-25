# VDP timing simulation

`./run.sh` runs the V9938 in GHDL and reports the video timing it actually
produces, which must match the scaler geometry declared in
`pkg/pocket/Cores/plasticbugs.msx2/video.json`.

Expected output for NTSC (`FORCED_V_MODE = 0`, `DISPRESO = 0`):

```
FIELD n: hsync pulses = 262 | lines with DE = 242
LINE: 1368 clk21 per hsync | DE width 1196 clk21 (= 598 px at 10.74MHz)
```

so `video.json` scaler mode 0 is 598x242. PAL (`FORCED_V_MODE = 1`) gives
313 lines per field with 293 active, i.e. scaler mode 1 is 598x293.

The sources under `src/` are generated copies, patched for simulation only
(GHDL requires complete CASE statements, and the VGA-path line buffer is
indexed out of range in 15kHz mode). Synthesis uses `modules/video-v9938/`
directly and is unaffected.

## Blanking for the Analogizer

The Analogizer's SVGA scandoubler (`target/pocket/analogizer/scandoubler_2.v`)
times every output line from the *Hblank* edges of its input, so the VDP
exports its display window split into `PVIDEO_HBLANK` / `PVIDEO_VBLANK`
(registered alongside `PVIDEODE`, so `DE == NOT (HBLANK OR VBLANK)` exactly).
Two benches cover that path:

- `./run_blank.sh` measures the exported blanking against the sync pulses in
  GHDL, NTSC and PAL. Expected: 262 / 313 lines per field, Hblank pulsing on
  every line including the 20 vertical-blanking lines, 1368-clock lines with
  173 clocks of Hblank, the 100-clock Hsync pulse starting 1 clock into
  Hblank, and `de_mismatch=0`.
- `tb_scandoubler.v` drives `scandoubler_2` with that timing (build line in
  the file header; needs Verilator) and checks for two Hsync pulses and two
  intact copies of every input line, one Vsync per field, and an Hblank that
  toggles every output line. It passes with `LENGTH=684` (a full MSX line at
  the 10.74 MHz pixel enable) and shows the right half of every line
  corrupted with the `LENGTH=290` the Analogizer hook originally shipped with.
