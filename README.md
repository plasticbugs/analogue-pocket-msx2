# MSX2 for Analogue Pocket

An MSX2 home computer core for the Analogue Pocket (openFPGA), built on the
[OpenGateware MSX core](https://github.com/opengateware/computer-msx) and
upgraded from MSX1 to MSX2.

Metal Gear 2, SD Snatcher, Space Manbow, Aleste 2 and the rest of the MSX2
library, in your pocket — with automatic mapper detection, so nearly every
game loads with zero configuration.

## Installing

1. Download the latest `msx2-pocket-sdcard.zip` from
   [Releases](https://github.com/plasticbugs/analogue-pocket-msx2/releases).
2. Unzip it onto the root of your Pocket's SD card, merging folders and
   overwriting when asked.
3. Put cartridge `.rom` images in `Assets/msx2/common/`.
4. On the Pocket: **openFPGA → MSX2**, then load a game through
   **Core Settings → Load Slot A**.

Updater apps such as [Pocket Sync](https://github.com/neil-morrison44/pocket-sync)
can also install and update the core directly from this repository's
releases.

Upgrading from a release before v0.4.0: the core moved from
`Cores/boogermann.msx` to `Cores/plasticbugs.msx2` and its assets from
`Assets/msx/common` to `Assets/msx2/common`. Move your ROM/BIOS files to the
new assets folder and delete the old `Cores/boogermann.msx`,
`Platforms/msx.json`, and `Platforms/_images/msx.bin`.

## Features

- **V9938 VDP** (ESE-VDP implementation) with 128 kB VRAM — all MSX2 screen
  modes including 512-pixel and bitmap modes, sprites mode 2, and the VDP
  command engine
- **13 cartridge mappers with automatic detection**: known dumps are
  identified by SHA-1 against a database distilled from the
  [openMSX Software Database](https://openmsx.org/) (3,200+ entries);
  unknown dumps fall back to signature analysis. Konami, Konami SCC (with
  SCC sound), ASCII8/16 (+SRAM variants), Game Master 2, R-Type,
  Cross Blaim, Harry Fox, Super Lode Runner, generic 8 kB, linear
- **Two cartridge slots** loaded from SDRAM (up to 4 MB per slot)
- **256 kB memory-mapper RAM** — enough for SD Snatcher and other
  128 kB+ disk conversions — plus RP-5C01 RTC
- **C-BIOS MSX2** system ROMs embedded in the bitstream — cartridge games
  boot with no BIOS files at all
- **Bring-your-own-BIOS**: load a real machine's BIOS at runtime for
  software that needs BASIC or disk routines (see below)
- **Joy2Key**: d-pad types the cursor keys; Y/X/L/R/Select/Start map to
  your choice of keyboard keys (SPACE, RETURN, SHIFT, letters, digits,
  function keys...) from the Core Settings menus — enough to play
  keyboard-driven games without a keyboard
- PSG (AY-3-8910), keyboard via USB dock
- NTSC/PAL output with automatic scaler preset switching

## Using a real MSX BIOS

C-BIOS (the built-in open-source BIOS) runs cartridge games perfectly but
contains no BASIC and no disk routines. Games that need them — including
`.dsk` images converted to ROM with dsk2rom — need a real machine's BIOS,
which you supply yourself:

1. Place two dumps from the **same machine** in `Assets/msx2/common/`:
   - the 32 kB main BIOS+BASIC ROM
   - the matching 16 kB MSX2 sub (ext) ROM
2. In Core Settings, use **Load Main BIOS**, then **Load Sub (ext) ROM**.
3. Load your game as usual.

Loading only one of the pair, or mixing machines, will hang the core.
Quitting and relaunching the core always restores C-BIOS. No copyrighted
BIOS is included in this repository or its releases.

## Known limitations

- Rarely, a stray line of pixels appears at the bottom of the screen
  after loading a game; restarting the core sometimes clears it
- No floppy drive emulation yet — convert `.dsk` software to `.rom` with
  [dsk2rom](https://github.com/joyrex2001/dsk2rom) (multi-disk software
  needs each disk converted separately)
- Cartridge SRAM is not yet persisted to the SD card, so battery-backed
  saves (Xanadu, Hydlide 2, Game Master 2...) don't survive a power cycle
- No MSX-MUSIC/OPLL yet

## Building

Local (requires Docker):

```sh
./build-local.sh
```

Or push to GitHub — `.github/workflows/compile.yml` compiles the core with
Quartus 18.1 and uploads the ready-to-use SD card package as an artifact.

The build output in `release/pocket/` is copied onto the root of the
Pocket's SD card.

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
- The mapper database (`Assets/msx2/common/mapperdb.bin`) is distilled
  from the openMSX Software Database (SHA-1 prefixes and mapper types
  only; no game data).

## Acknowledgements

- Kunihiko Ohnaka and the ESE Artists' Factory for the ESE MSX-System,
  the basis of nearly every FPGA MSX in existence
- Molekula for the MSX1 core this is built on
- Marcus Andrade (boogermann) and the OpenGateware project for the Pocket
  framework and the original Pocket port
- The C-BIOS Association for a freely redistributable MSX BIOS
- The openMSX project for the Software Database that powers mapper
  auto-detection
- The MiSTer project for maintaining the OCM-derived MSX core
