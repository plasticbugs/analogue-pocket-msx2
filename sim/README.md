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
