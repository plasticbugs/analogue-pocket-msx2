# MSX2 for Analogue Pocket

An MSX2 home computer core for the Analogue Pocket (openFPGA), built on the
[OpenGateware MSX core](https://github.com/opengateware/computer-msx) and
upgraded from MSX1 to MSX2.

## Features

- **V9938 VDP** (ESE-VDP implementation) with 128 kB VRAM — all MSX2 screen
  modes including 512-pixel and bitmap modes, sprites mode 2, and the VDP
  command engine
- **C-BIOS MSX2** system ROMs embedded in the bitstream — no BIOS files
  needed on the SD card (cartridge games boot directly; C-BIOS contains no
  BASIC and no disk support)
- 64 kB memory-mapper RAM (slot 3-2, I/O 0xFC–0xFF) and RP-5C01 RTC
- Two cartridge slots loaded from SDRAM (up to 4 MB per slot) with
  auto-detected MegaROM mappers: Konami, Konami SCC (with SCC sound),
  ASCII8 (+8 kB SRAM), ASCII16 (+2 kB SRAM), Game Master 2, R-Type, linear
- PSG (AY-3-8910), keyboard via USB dock or joypad-to-key mapping
- NTSC/PAL output with automatic scaler preset switching

## Building

Local (requires Docker):

```sh
./build-local.sh
```

Or push to GitHub — `.github/workflows/compile.yml` compiles the core with
Quartus 18.1 and uploads the ready-to-use SD card package as an artifact.

The build output in `release/pocket/` is copied onto the root of the
Pocket's SD card. Load cartridge `.rom` images through the core's
Slot A / Slot B menu.

## License

This project as a whole is distributed under the
**GNU General Public License v3.0 or later** — see [LICENSE](LICENSE).

It is a derivative work combining several open-source components. Each
retains its own copyright and license, preserved in the source headers:

| Component | Path | Author / Copyright | License |
|---|---|---|---|
| MSX core (base, MSX1) | `rtl/`, `projects/` | © 2022 Molekula (@tdlabac); © 2024 OpenGateware authors | GPL-3.0-or-later |
| Pocket platform framework | `platform/pocket/` | © 2023 Marcus Andrade (OpenGateware); © 2022 Analogue Enterprises Ltd. | MIT |
| ESE-VDP (V9938) | `modules/video-v9938/` | © 2000-2006 Kunihiko Ohnaka (ESE Artists' Factory) | ESE license (BSD-style; source and binary redistribution permitted with notice; **no commercial use without permission**) |
| RP-5C01 RTC | `rtl/rtc.vhd` | ESE MSX-System / OneChipMSX authors | ESE license (as above) |
| T80 Z80 CPU | `modules/cpu-t80/` | © Daniel Wallner | BSD-style |
| JT49 PSG | `modules/sound-jt49/` | © Jose Tejada (@topapate) | GPL-3.0 |
| jt8255 PPI | `rtl/jt8255.v` | © Jose Tejada (@topapate) | GPL-3.0 |
| C-BIOS system ROMs | `rtl/rom/cbios_*.mif` | © the C-BIOS Association | 2-clause BSD |
| MSX2 additions in this repo | `rtl/msx2.sv` and related changes | © 2026 contributors | GPL-3.0-or-later |

Notes:

- The ESE-VDP license (see the header of `modules/video-v9938/vdp.vhd`;
  the Japanese text is normative) forbids selling this software or using
  it in a commercial product or activity without prior written permission
  from the copyright holder. **This core is therefore strictly
  non-commercial.**
- [C-BIOS](https://cbios.sourceforge.net/) is an open-source MSX BIOS
  written from scratch; redistribution is permitted under its 2-clause
  BSD license. No Microsoft/ASCII ROMs are included.
- The V9938 sources were taken from the
  [MiSTer MSX core](https://github.com/MiSTer-devel/MSX_MiSTer), which
  packages the ESE MSX-System 3 / OneChipMSX (OCM) codebase.

## Acknowledgements

- Kunihiko Ohnaka and the ESE Artists' Factory for the ESE MSX-System,
  the basis of nearly every FPGA MSX in existence
- Molekula for the MSX1 core this is built on
- Marcus Andrade (boogermann) and the OpenGateware project for the Pocket
  framework and the original Pocket port
- The C-BIOS Association for a freely redistributable MSX BIOS
- The MiSTer project for maintaining the OCM-derived MSX core
