//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// MSX2 Compatible Gateware IP Core
//
// Based on the MSX1 core by Molekula <@tdlabac> with the V9938 VDP from the
// ESE MSX-System (ESE Artists' Factory) as used in the MiSTer MSX core.
//
// Machine layout (C-BIOS MSX2):
//   Slot 0      : Main ROM 32kB (0000-7FFF) + Logo ROM 16kB (8000-BFFF)
//   Slot 1      : Cartridge A
//   Slot 2      : Cartridge B
//   Slot 3-0    : Sub ROM 16kB (0000-3FFF)
//   Slot 3-2    : Memory mapper RAM 128kB (I/O FC-FF)
//   I/O 98-9B   : V9938 VDP (128kB VRAM)
//   I/O A0-A3   : AY-3-8910 PSG
//   I/O A8-AB   : 8255 PPI
//   I/O B4-B5   : RP-5C01 RTC
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <http://www.gnu.org/licenses/>.
//
//------------------------------------------------------------------------------
// clk MUST be 21.477270 MHz: the V9938 uses it directly as its pixel engine
// clock. ce_10m7 is a 50% enable on clk used to derive the 3.58MHz CPU enables.
//------------------------------------------------------------------------------

module msx2
    (
        input         clk,
        input         ce_10m7,
        input         reset_i,
        // Video
        output  [7:0] R,
        output  [7:0] G,
        output  [7:0] B,
        output        hsync_n,
        output        vsync_n,
        output        video_de,
        input         vdp_pal,
        // Audio
        output [15:0] audio,
        // Keyboard
        input  [10:0] ps2_key,
        // Gamepad/Joystick
        input   [5:0] joy0,
        input   [5:0] joy1,
        // I/O Controller
        input         ioctl_download,
        input   [7:0] ioctl_index,
        input         ioctl_wr,
        input  [24:0] ioctl_addr,
        input   [7:0] ioctl_dout,
        input         ioctl_isROMA,
        input         ioctl_isROMB,
        input         ioctl_isBIOS,
        input         ioctl_isFWBIOS,
        input         ioctl_isSUBBIOS,
        input         ioctl_isMAPDB,
        output        ioctl_wait,
        // Cassette
        output        cas_motor,
        input         cas_audio_in,
        // User Mode
        input   [1:0] rom_enabled,
        input   [3:0] slot_A,
        input   [3:0] slot_B,
        output  [3:0] mapper_info,
        // SDRAM
        input   [7:0] sdram_dout,
        output  [7:0] sdram_din,
        output [24:0] sdram_addr,
        output        sdram_we,
        output        sdram_rd,
        input         sdram_ready,
        input   [1:0] sdram_size,
        // VHD Image
        input         img_mounted,
        input  [31:0] img_size,
        input         img_wp,
        output [31:0] sd_lba,
        output        sd_rd,
        output        sd_wr,
        input         sd_ack,
        input   [8:0] sd_buff_addr,
        input   [7:0] sd_buff_dout,
        output  [7:0] sd_buff_din,
        input         sd_buff_wr,
        input         sd_din_strobe
    );

    //--------------------------------------------------------------------------
    // Reset with VRAM wipe
    //
    // When the external reset releases (ROM load finished, mapper changed,
    // reset button), hold the machine in reset ~3ms longer while both VRAM
    // banks are written to zero, so every boot starts from the clean state
    // games expect from cold hardware.
    //--------------------------------------------------------------------------
    reg [16:0] vram_clr_cnt = 17'h10000;
    reg        reset_i_d;

    wire        vram_clearing = ~vram_clr_cnt[16];
    wire [15:0] vram_clr_addr = vram_clr_cnt[15:0];
    wire        reset         = reset_i | vram_clearing | verifying | db_scanning | db_pending;

    localparam VRAM_WIPE = 1;

    always @(posedge clk) begin
        reset_i_d <= reset_i;
        if (VRAM_WIPE && reset_i_d & ~reset_i) begin
            vram_clr_cnt <= 0;
        end
        else if (vram_clearing) begin
            vram_clr_cnt <= vram_clr_cnt + 1'd1;
        end
    end

    //--------------------------------------------------------------------------
    // Audio MIX
    //--------------------------------------------------------------------------
    // The AY PSG mix is unipolar (0..16368 once shifted). Cartridge (SCC)
    // sound is a raw digital sum that the real cartridge runs through an
    // analog stage at roughly PSG-comparable loudness -- Konami relies on
    // that and plays Metal Gear 2's melody at SCC volume 1-2 of 15, which
    // came through ~26dB under the PSG here (verified by replaying the
    // game's ripped SCC state in sim/tb_scc_mg2.vhd: clean output, +/-700
    // peak). Boost the cartridge sound x4, sum wide, halve, and saturate;
    // realistic worst cases stay well inside 16 bits, so the old hard-clip
    // distortion cannot return.
    wire  [9:0] audioPSG   = ay_ch_mix + {keybeep, 5'b00000} + {(cas_audio_in & ~cas_motor), 4'b0000};
    wire [15:0] fm         = {2'b0, audioPSG, 4'b0000};
    wire [18:0] audio_mix  = {{3{fm[15]}}, fm} + {sound_slots[15], sound_slots, 2'b00};
    wire [17:0] audio_half = audio_mix[18:1];

    assign audio = (audio_half[17:15] == 3'b000 ||
                    audio_half[17:15] == 3'b111) ? audio_half[15:0]
                                                 : (audio_half[17] ? 16'h8000 : 16'h7FFF);

    //--------------------------------------------------------------------------
    // Clock generation
    //--------------------------------------------------------------------------
    wire clk_en_3m58_p, clk_en_3m58_n;

    cv_clock clock
    (
        .clk_i           ( clk           ),
        .clk_en_10m7_i   ( ce_10m7       ),
        .reset_n_i       ( ~reset        ),
        .clk_en_3m58_p_o ( clk_en_3m58_p ),
        .clk_en_3m58_n_o ( clk_en_3m58_n )
    );

    //--------------------------------------------------------------------------
    // Z80 CPU
    //--------------------------------------------------------------------------
    wire [15:0] a;
    wire  [7:0] d_to_cpu, d_from_cpu;
    wire        mreq_n, wr_n, m1_n, iorq_n, rd_n, rfrsh_n, wait_n;

    // WAIT while a cartridge or mapper-RAM SDRAM read is outstanding (ready
    // is registered and drops a few clocks after the request; the T80
    // samples WAIT late enough in T2 to see it). Writes post freely: a
    // following access waits naturally because ready stays low until the
    // write completes.
    wire sdram_wait_n = ~((slots_sdram_rd | mapram_rd) & ~sdram_ready);

    t80pa #(.Mode(0)) u_t80
    (
        .RESET_n ( ~reset        ),
        .CLK     ( clk           ),
        .CEN_p   ( clk_en_3m58_p ),
        .CEN_n   ( clk_en_3m58_n ),
        .WAIT_n  ( wait_n & sdram_wait_n ),
        .INT_n   ( vdp_int_n     ),
        .NMI_n   ( 1             ),
        .BUSRQ_n ( 1             ),
        .M1_n    ( m1_n          ),
        .MREQ_n  ( mreq_n        ),
        .IORQ_n  ( iorq_n        ),
        .RD_n    ( rd_n          ),
        .WR_n    ( wr_n          ),
        .RFSH_n  ( rfrsh_n       ),
        .HALT_n  ( 1             ),
        .BUSAK_n (               ),
        .A       ( a             ),
        .DI      ( d_to_cpu      ),
        .DO      ( d_from_cpu    )
    );

    //--------------------------------------------------------------------------
    // WAIT (M1 wait state, as on real MSX)
    //--------------------------------------------------------------------------
    wire u1_2_q;
    wire exwait_n = 1;

    ls74 u1_1
    (
        .clr ( exwait_n      ),
        .pre ( u1_2_q        ),
        .clk ( clk_en_3m58_p ),
        .d   ( m1_n          ),
        .q   ( wait_n        )
    );

    ls74 u1_2
    (
        .clr ( 1             ),
        .pre ( exwait_n      ),
        .clk ( clk_en_3m58_p ),
        .d   ( wait_n        ),
        .q   ( u1_2_q        )
    );

    //--------------------------------------------------------------------------
    // Device request strobe (emsx style: one clk pulse per CPU access)
    //
    // The CPU bus is registered before it reaches the devices, as the reference
    // implementation does, so that address, data and the read/write strobes all
    // present to the VDP on the same edge. Building the strobe combinationally
    // from the raw T80 outputs lets them arrive fractionally apart, which
    // intermittently mistimes an access. That is not benign here: a VDP palette
    // entry is written as two consecutive bytes, so one mistimed access desyncs
    // the whole palette (a green cast), and the sprite attribute writes fail
    // the same way. Both symptoms varied from boot to boot.
    //--------------------------------------------------------------------------
    reg         r_mreq_n, r_iorq_n, r_rd_n, r_wr_n, r_m1_n;
    reg  [15:0] r_a;
    reg   [7:0] r_d;
    reg         iack;

    wire req = ((~r_mreq_n | ~r_iorq_n) & (~r_rd_n | ~r_wr_n) & ~iack);

    always @(posedge clk) begin
        if (reset) begin
            r_mreq_n <= 1'b1;
            r_iorq_n <= 1'b1;
            r_rd_n   <= 1'b1;
            r_wr_n   <= 1'b1;
            r_m1_n   <= 1'b1;
            r_a      <= 16'hFFFF;
            r_d      <= 8'hFF;
            iack     <= 1'b0;
        end
        else begin
            r_mreq_n <= mreq_n;
            r_iorq_n <= iorq_n;
            r_rd_n   <= rd_n;
            r_wr_n   <= wr_n;
            r_m1_n   <= m1_n;
            r_a      <= a;
            r_d      <= d_from_cpu;

            if (r_mreq_n & r_iorq_n) begin
                iack <= 1'b0;
            end
            else if (req) begin
                iack <= 1'b1;
            end
        end
    end

    // Requests are decoded from the registered bus so they stay aligned with
    // the address and data the devices are given.
    wire r_io_en   = ~r_iorq_n & r_m1_n;
    wire r_vdp_sel = r_io_en & (r_a[7:2] == 6'b100110);  // 98-9B
    wire r_rtc_sel = r_io_en & (r_a[7:1] == 7'b1011010); // B4-B5
    wire r_wrt     = ~r_wr_n;

    wire vdp_req  = req & r_vdp_sel;
    wire rtc_req  = req & r_rtc_sel;

    // The read multiplexer stays on the live bus so data is back well within
    // the CPU's access window.
    wire io_en    = ~iorq_n & m1_n;
    wire vdp_sel  = io_en & (a[7:2] == 6'b100110);  // 98-9B
    wire rtc_sel  = io_en & (a[7:1] == 7'b1011010); // B4-B5
    wire map_sel  = io_en & (a[7:2] == 6'b111111);  // FC-FF

    //--------------------------------------------------------------------------
    // BIOS ROMs (C-BIOS MSX2: main 32kB, logo 16kB, sub 16kB)
    //--------------------------------------------------------------------------
    wire [7:0] rom_q;
    wire [7:0] fw_rom_q;
    wire [7:0] sub_rom_q;

    spram #(.addr_width(15), .mem_init_file("rom/cbios_main_msx2.mif"), .mem_name("ROM")) rom
    (
        .clock   ( clk          ),
        .address ( ioctl_isBIOS ? ioctl_addr[14:0] : a[14:0] ),
        .q       ( rom_q        ),
        .wren    ( ioctl_isBIOS ),
        .data    ( ioctl_dout   )
    );

    spram #(.addr_width(14), .mem_init_file("rom/cbios_logo_msx2.mif"), .mem_name("FWROM")) fw_rom
    (
        .clock   ( clk            ),
        .address ( ioctl_isFWBIOS ? ioctl_addr[13:0] : a[13:0] ),
        .q       ( fw_rom_q       ),
        .wren    ( ioctl_isFWBIOS ),
        .data    ( ioctl_dout     )
    );

    spram #(.addr_width(14), .mem_init_file("rom/cbios_sub.mif"), .mem_name("SUBROM")) sub_rom
    (
        .clock   ( clk             ),
        .address ( ioctl_isSUBBIOS ? ioctl_addr[13:0] : a[13:0] ),
        .q       ( sub_rom_q       ),
        .wren    ( ioctl_isSUBBIOS ),
        .data    ( ioctl_dout      )
    );

    //--------------------------------------------------------------------------
    // Video RAM 128k (two 64k banks side by side on a 16bit read bus,
    // bank selected by address bit 16)
    //
    // The banks are wiped by the reset sequencer below: BRAM contents
    // otherwise survive every reset short of an FPGA reconfigure, so a
    // reloaded game would boot into the previous game's VRAM. C-BIOS does
    // not clear VRAM, and games written for cold hardware assume it is
    // clean -- Bubble Bobble's sprites break and it eventually crashes when
    // its tables sit on leftovers.
    //--------------------------------------------------------------------------
    wire [16:0] vdp_pram_a;
    wire  [7:0] vdp_pram_do;
    wire        vdp_pramwe_n;
    wire  [7:0] vram0_q, vram1_q;

    wire [15:0] vram_a    = vram_clearing ? vram_clr_addr    : vdp_pram_a[15:0];
    wire  [7:0] vram_d    = vram_clearing ? 8'h00            : vdp_pram_do;
    wire        vram0_we  = vram_clearing ? 1'b1 : (~vdp_pramwe_n & ~vdp_pram_a[16]);
    wire        vram1_we  = vram_clearing ? 1'b1 : (~vdp_pramwe_n &  vdp_pram_a[16]);

    spram #(.addr_width(16), .mem_name("VRAM0")) vram0
    (
        .clock   ( clk      ),
        .address ( vram_a   ),
        .wren    ( vram0_we ),
        .data    ( vram_d   ),
        .q       ( vram0_q  )
    );

    spram #(.addr_width(16), .mem_name("VRAM1")) vram1
    (
        .clock   ( clk      ),
        .address ( vram_a   ),
        .wren    ( vram1_we ),
        .data    ( vram_d   ),
        .q       ( vram1_q  )
    );

    //--------------------------------------------------------------------------
    // V9938 Video Display Processor
    //--------------------------------------------------------------------------
    wire [7:0] d_from_vdp;
    wire       vdp_int_n;
    wire [5:0] vdp_r, vdp_g, vdp_b;

    VDP vdp
    (
        .CLK21M          ( clk           ),
        .RESET           ( reset         ),
        .REQ             ( vdp_req       ),
        .ACK             (               ),
        .WRT             ( r_wrt         ),
        .ADR             ( r_a           ),
        .DBI             ( d_from_vdp    ),
        .DBO             ( r_d           ),

        .INT_N           ( vdp_int_n     ),

        .PRAMOE_N        (               ),
        .PRAMWE_N        ( vdp_pramwe_n  ),
        .PRAMADR         ( vdp_pram_a    ),
        .PRAMDBI         ( {vram1_q, vram0_q} ),
        .PRAMDBO         ( vdp_pram_do   ),

        .VDPSPEEDMODE    ( 1'b0          ),
        .RATIOMODE       ( 3'b000        ),
        .CENTERYJK_R25_N ( 1'b1          ),

        .PVIDEOR         ( vdp_r         ),
        .PVIDEOG         ( vdp_g         ),
        .PVIDEOB         ( vdp_b         ),
        .PVIDEODE        ( vdp_de        ),

        .PVIDEOHS_N      ( hsync_n       ),
        .PVIDEOVS_N      ( vsync_n       ),
        .PVIDEOCS_N      (               ),

        .PVIDEODHCLK     (               ),
        .PVIDEODLCLK     (               ),

        .DISPRESO        ( 1'b0          ), // 15kHz
        .NTSC_PAL_TYPE   ( ~vdp_pal      ), // 1: follow VDP R9 PAL bit, 0: forced
        .FORCED_V_MODE   ( vdp_pal       ),
        .LEGACY_VGA      ( 1'b0          ),
        .PVIDEO_WINDOW_Y ( vdp_win_y     )
    );

    //--------------------------------------------------------------------------
    // DIAGNOSTIC overlay: paint the first 32 and the last 8 visible lines in
    // counted 8-line colour bands (red/green/blue/white from the top; magenta
    // then cyan at the bottom; odd lines dimmed) so a photograph of the panel
    // reveals exactly which output lines the Pocket scaler displays and which
    // it crops. Set DIAG_LINES = 0 for normal releases.
    //--------------------------------------------------------------------------
    localparam DIAG_LINES      = 0;
    localparam DIAG_INDICATORS = 0;

    wire [8:0] vis_line  = de_line_cnt - v_trim - 1'd1;
    wire [8:0] last_band = vdp_pal ? 9'd280 : 9'd232;

    // horizontal position within the DE line, so the bars can be confined to
    // the left quarter and the game stays visible beside them
    reg [10:0] x_cnt;
    always @(posedge clk) begin
        if (!vdp_de) x_cnt <= 0;
        else         x_cnt <= x_cnt + 1'd1;
    end

    reg  [23:0] diag_rgb;
    reg         diag_on;

    always @* begin
        diag_on  = 1'b0;
        diag_rgb = 24'h000000;
        // cart diagnostics overlay (top-left, bright = 1, MSB first) --
        // enable via DIAG_INDICATORS when chasing load/data problems:
        //   row 1 (lines 2-5):   active mapper, 4 squares
        //   row 2 (lines 8-11):  ROM stream checksum (8-bit sum), 8 squares
        //   row 3 (lines 14-17): rom_size[20:13], 8 squares
        if (DIAG_INDICATORS && vis_line >= 9'd2 && vis_line < 9'd6 && x_cnt < 11'd128) begin
            diag_on  = 1'b1;
            diag_rgb = active_mapper_A[3 - x_cnt[6:5]] ? 24'hFFFF00 : 24'h202020;
            if (x_cnt[4:0] < 4) diag_rgb = 24'h000000;  // gap between squares
        end
        else if (DIAG_INDICATORS && vis_line >= 9'd8 && vis_line < 9'd12 && x_cnt < 11'd256) begin
            diag_on  = 1'b1;
            diag_rgb = stream_sum_A[3'd7 - x_cnt[7:5]] ? 24'h00FFFF : 24'h202020;
            if (x_cnt[4:0] < 4) diag_rgb = 24'h000000;
        end
        else if (DIAG_INDICATORS && vis_line >= 9'd14 && vis_line < 9'd18 && x_cnt < 11'd256) begin
            diag_on  = 1'b1;
            diag_rgb = rom_size_A[5'd20 - x_cnt[7:5]] ? 24'hFF00FF : 24'h202020;
            if (x_cnt[4:0] < 4) diag_rgb = 24'h000000;
        end
        else if (DIAG_INDICATORS && vis_line >= 9'd20 && vis_line < 9'd24 && x_cnt < 11'd256) begin
            // row 4: SDRAM readback checksum (green) -- must match row 2
            diag_on  = 1'b1;
            diag_rgb = verify_sum[3'd7 - x_cnt[7:5]] ? 24'h00FF00 : 24'h202020;
            if (x_cnt[4:0] < 4) diag_rgb = 24'h000000;
        end
        else if (DIAG_INDICATORS && vis_line >= 9'd26 && vis_line < 9'd30 && x_cnt < 11'd256) begin
            // row 5 (white): database status --
            //   {db_loaded, 0, 0, db_valid_A, db_mapper_A[3:0]}
            diag_on  = 1'b1;
            diag_rgb = db_status[3'd7 - x_cnt[7:5]] ? 24'hFFFFFF : 24'h202020;
            if (x_cnt[4:0] < 4) diag_rgb = 24'h000000;
        end
        else if (DIAG_LINES && x_cnt < 11'd280) begin
            if (vis_line < 9'd32) begin
                diag_on = 1'b1;
                case ({vis_line[4:3], vis_line[0]})
                    3'b000: diag_rgb = 24'hFF0000;  // lines  0-7  red
                    3'b001: diag_rgb = 24'h700000;
                    3'b010: diag_rgb = 24'h00FF00;  // lines  8-15 green
                    3'b011: diag_rgb = 24'h007000;
                    3'b100: diag_rgb = 24'h0060FF;  // lines 16-23 blue
                    3'b101: diag_rgb = 24'h002870;
                    3'b110: diag_rgb = 24'hFFFFFF;  // lines 24-31 white
                    3'b111: diag_rgb = 24'h707070;
                endcase
            end
            else if (vis_line >= last_band && vis_line < last_band + 9'd8) begin
                diag_on  = 1'b1;
                if (vis_line >= last_band + 9'd4)
                    diag_rgb = vis_line[0] ? 24'h007070 : 24'h00FFFF;  // last 4: cyan
                else
                    diag_rgb = vis_line[0] ? 24'h700070 : 24'hFF00FF;  // magenta
            end
        end
    end

    // The VDP's vertical window (PVIDEO_WINDOW_Y) is exported and was once
    // used to paint over the last active display line; the stray bottom line
    // some sessions show turned out to be a Pocket scaler capture-phase
    // artifact (intermittent, cleared by a core restart), which no in-picture
    // repaint can address. sim/tb_winy.vhd documents the signal's timing:
    // it tracks the fetch line, one scan line ahead of the picture.
    wire vdp_win_y;

    assign R = diag_on ? diag_rgb[23:16] : {vdp_r, vdp_r[5:4]};
    assign G = diag_on ? diag_rgb[15:8]  : {vdp_g, vdp_g[5:4]};
    assign B = diag_on ? diag_rgb[7:0]   : {vdp_b, vdp_b[5:4]};

    //--------------------------------------------------------------------------
    // Display enable trim
    //
    // Horizontal: the VDP's colour pipeline has not settled when its display
    // window opens, so the first pixel of every line carries a stale colour.
    // A CRT hides it in overscan; the Pocket scaler shows it as a stray column
    // down the left edge. Drop the first DE_TRIM clocks of the window -- two
    // output samples, which keeps the two-samples-per-MSX-pixel alignment.
    //
    // Vertical: the V9938's raw window is 242 lines (NTSC) / 293 (PAL), which
    // forces the Pocket scaler into a non-integer vertical scale on its
    // 1440-pixel panel (5.95x / 4.91x). Dropping the first 2 lines (NTSC) or
    // 5 lines (PAL) yields 240 / 288 lines -- an exact 6x / 5x panel fit --
    // and, because the VDP's top border is 2 lines (NTSC) or 5 lines (PAL)
    // taller than its bottom border, it also centres the picture exactly in
    // both the 192-line and 212-line display modes.
    //
    // video.json must match: 596 x 240 (NTSC) and 596 x 288 (PAL).
    //--------------------------------------------------------------------------
    localparam DE_TRIM = 4;

    wire       vdp_de;
    reg  [2:0] de_cnt;

    always @(posedge clk) begin
        if (!vdp_de) begin
            de_cnt <= 0;
        end
        else if (de_cnt != DE_TRIM[2:0]) begin
            de_cnt <= de_cnt + 1'd1;
        end
    end

    wire [8:0] v_trim = vdp_pal ? 9'd5 : 9'd2;

    reg  [8:0] de_line_cnt;
    reg        vdp_de_d, vs_n_d;

    always @(posedge clk) begin
        vdp_de_d <= vdp_de;
        vs_n_d   <= vsync_n;
        if (vs_n_d & ~vsync_n) begin
            de_line_cnt <= 0;
        end
        else if (vdp_de & ~vdp_de_d & ~(&de_line_cnt)) begin
            de_line_cnt <= de_line_cnt + 1'd1;
        end
    end

    // de_line_cnt is 1 on the first window line; it increments at line start,
    // before the horizontal trim releases any visible pixel of that line.
    wire v_visible = (de_line_cnt > v_trim);

    assign video_de = vdp_de & (de_cnt == DE_TRIM[2:0]) & v_visible;

    //--------------------------------------------------------------------------
    // RP-5C01 RTC
    //--------------------------------------------------------------------------
    wire [7:0] d_from_rtc;

    // 10Hz enable for the RTC second counter (21.47727MHz / 2147727)
    reg [21:0] rtc_div = 0;
    reg        rtc_ce_10hz = 0;

    always @(posedge clk) begin
        rtc_ce_10hz <= 0;
        if (rtc_div == 22'd2147726) begin
            rtc_div     <= 0;
            rtc_ce_10hz <= 1;
        end
        else begin
            rtc_div <= rtc_div + 1'd1;
        end
    end

    rtc rtc
    (
        .clk21m ( clk         ),
        .reset  ( reset       ),
        .setup  ( 1'b0        ),
        .rt     ( 65'd0       ),
        .clkena ( rtc_ce_10hz ),
        .req    ( rtc_req     ),
        .ack    (             ),
        .wrt    ( r_wrt       ),
        .adr    ( r_a         ),
        .dbi    ( d_from_rtc  ),
        .dbo    ( r_d         )
    );

    //--------------------------------------------------------------------------
    // IO Decoder
    //--------------------------------------------------------------------------
    wire vdp_n, psg_n, ppi_n, cen_n;

    io_decoder io_decoder
    (
        .addr   ( a      ),
        .iorq_n ( iorq_n ),
        .m1_n   ( m1_n   ),
        .vdp_n  ( vdp_n  ),
        .psg_n  ( psg_n  ),
        .ppi_n  ( ppi_n  ),
        .cen_n  ( cen_n  )
    );

    //--------------------------------------------------------------------------
    // 82C55 PPI
    //--------------------------------------------------------------------------
    wire [7:0] d_from_8255;
    wire [7:0] ppi_out_a, ppi_out_c;
    wire       keybeep = ppi_out_c[7];

    assign     cas_motor =  ppi_out_c[4];

    jt8255 PPI
    (
        .rst        ( reset       ),
        .clk        ( clk         ),
        .addr       ( a[1:0]      ),
        .din        ( d_from_cpu  ),
        .dout       ( d_from_8255 ),
        .rdn        ( rd_n        ),
        .wrn        ( wr_n        ),
        .csn        ( ppi_n       ),

        .porta_din  ( 8'h0        ),
        .portb_din  ( d_from_kb   ),
        .portc_din  ( 8'h0        ),

        .porta_dout ( ppi_out_a   ),
        .portb_dout (             ),
        .portc_dout ( ppi_out_c   )
    );

    //--------------------------------------------------------------------------
    // Primary slot select
    //--------------------------------------------------------------------------
    wire [3:0] SLTSL_n;
    wire       CS1_n, CS01_n, CS12_n, CS2_n;

    memory_mapper memory_mapper
    (
        .reset   ( reset     ),
        .addr    ( a         ),
        .ppi_n   ( ppi_n     ),
        .RAM_CS  ( ppi_out_a ),
        .mreq_n  ( mreq_n    ),
        .rfrsh_n ( rfrsh_n   ),
        .rd_n    ( rd_n      ),
        .SLTSL_n ( SLTSL_n   ),
        .CS1_n   ( CS1_n     ),
        .CS01_n  ( CS01_n    ),
        .CS12_n  ( CS12_n    ),
        .CS2_n   ( CS2_n     )
    );

    //--------------------------------------------------------------------------
    // Slot 3 secondary slot expander
    //--------------------------------------------------------------------------
    reg  [7:0] exp3_reg;
    wire       slot3_en   = ~SLTSL_n[3];
    wire       exp3_sel   = slot3_en & (a == 16'hFFFF);
    wire [1:0] page       = a[15:14];
    wire [1:0] subslot3   = exp3_reg[{page, 1'b0} +: 2];

    always @(posedge clk) begin
        if (reset) begin
            exp3_reg <= 8'h00;
        end
        else if (exp3_sel & ~wr_n & clk_en_3m58_p) begin
            exp3_reg <= d_from_cpu;
        end
    end

    wire sltsl30 = slot3_en & ~exp3_sel & (subslot3 == 2'd0);
    wire sltsl32 = slot3_en & ~exp3_sel & (subslot3 == 2'd2);

    // Slot 3-0: C-BIOS Sub ROM, 0000-3FFF
    wire sub_rom_en = sltsl30 & (page == 2'b00);

    //--------------------------------------------------------------------------
    // Slot 3-2: Memory mapper RAM, 256kB (16 segments of 16kB), I/O FC-FF
    //
    // The RAM lives in SDRAM (region 011): the FPGA has exactly 308 M10K
    // blocks and a 128kB BRAM mapper -- the minimum for SD Snatcher and
    // other late Konami titles, whose loaders check and refuse 64kB --
    // does not fit. Accesses ride the same CPU-paced WAIT-state path the
    // cartridge ROM reads use; moving it here also frees 64 blocks.
    //--------------------------------------------------------------------------
    // Only SEG_BITS of each segment register are implemented. The unimplemented
    // bits must read back as 1, because software sizes the mapper by writing a
    // segment number and reading it back: storing all 8 bits would advertise
    // 256 segments (4MB) while only SEG_BITS worth of RAM exists, and every
    // access above that would silently alias onto memory already in use.
    localparam SEG_BITS = 4; // 16 segments x 16kB = 256kB

    reg  [7:0] map_reg[3:0];
    wire [SEG_BITS-1:0] map_seg = map_reg[page][SEG_BITS-1:0];

    function [7:0] map_mask(input [7:0] seg);
        map_mask = {{(8-SEG_BITS){1'b1}}, seg[SEG_BITS-1:0]};
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            map_reg[0] <= map_mask(8'd3);
            map_reg[1] <= map_mask(8'd2);
            map_reg[2] <= map_mask(8'd1);
            map_reg[3] <= map_mask(8'd0);
        end
        else if (map_sel & ~wr_n & clk_en_3m58_p) begin
            map_reg[a[1:0]] <= map_mask(d_from_cpu);
        end
    end

    wire        mapram_rd   = sltsl32 & ~rd_n;
    wire        mapram_wr   = sltsl32 & ~wr_n;
    wire [24:0] mapram_addr = {3'b011, {(8-SEG_BITS){1'b0}}, map_seg, a[13:0]};

    //--------------------------------------------------------------------------
    // CPU data multiplex
    //--------------------------------------------------------------------------
    assign d_to_cpu = ~(CS01_n | SLTSL_n[0]) ? rom_q          :
                      ~(CS2_n  | SLTSL_n[0]) ? fw_rom_q       :
                      ~(SLTSL_n[1])          ? d_from_slots   :
                      ~(SLTSL_n[2])          ? d_from_slots   :
                      (exp3_sel & ~rd_n)     ? ~exp3_reg      :
                      (sub_rom_en & ~rd_n)   ? sub_rom_q      :
                      (sltsl32 & ~rd_n)      ? sdram_dout     :
                      (vdp_sel & ~rd_n)      ? d_from_vdp     :
                      (rtc_sel & ~rd_n)      ? d_from_rtc     :
                      (map_sel & ~rd_n)      ? map_reg[a[1:0]]:
                      ~(psg_n | rd_n)        ? d_from_psg     :
                      ~(ppi_n | rd_n)        ? d_from_8255    :
                      8'hFF;

    //--------------------------------------------------------------------------
    // Keyboard decoder
    //--------------------------------------------------------------------------
    wire [7:0] d_from_kb;

    keyboard msx_key
    (
        .reset_n_i  ( ~reset         ),
        .clk_i      ( clk            ),
        .ps2_code_i ( ps2_key        ),
        .kb_addr_i  ( ppi_out_c[3:0] ),
        .kb_data_o  ( d_from_kb      )
    );

    //--------------------------------------------------------------------------
    // Sound AY-3-8910
    //--------------------------------------------------------------------------
    wire [7:0] d_from_psg, psg_ioa, psg_iob;
    wire [5:0] joy_a = psg_iob[4] ? 6'b111111 : {~joy0[5], ~joy0[4], ~joy0[0], ~joy0[1], ~joy0[2], ~joy0[3]};
    wire [5:0] joy_b = psg_iob[5] ? 6'b111111 : {~joy1[5], ~joy1[4], ~joy1[0], ~joy1[1], ~joy1[2], ~joy1[3]};
    wire [5:0] joyA  = joy_a & {psg_iob[0], psg_iob[1], 4'b1111};
    wire [5:0] joyB  = joy_b & {psg_iob[2], psg_iob[3], 4'b1111};

    assign psg_ioa = {cas_audio_in,1'b0, psg_iob[6] ? joyB : joyA};

    wire [9:0] ay_ch_mix;

    wire u21_1_q;
    ls74 u21_1
    (
        .clr ( !psg_n        ),
        .pre ( 1             ),
        .clk ( clk_en_3m58_p ),
        .d   ( !psg_n        ),
        .q   ( u21_1_q       )
    );

    wire u21_2_q;
    ls74 u21_2
    (
        .clr ( !psg_n        ),
        .pre ( 1             ),
        .clk ( clk_en_3m58_p ),
        .d   ( u21_1_q       ),
        .q   ( u21_2_q       )
    );

    wire psg_e    = !(!u21_2_q | clk_en_3m58_p) | psg_n;
    wire psg_bc   = !(a[0] | psg_e);
    wire psg_bdir = !(a[1] | psg_e);

    jt49_bus PSG
    (
        .rst_n   ( ~reset        ),
        .clk     ( clk           ),
        .clk_en  ( clk_en_3m58_n ),
        .bdir    ( psg_bdir      ),
        .bc1     ( psg_bc        ),
        .din     ( d_from_cpu    ),
        .sel     ( 0             ),
        .dout    ( d_from_psg    ),
        .sound   ( ay_ch_mix     ),
        .A       (               ),
        .B       (               ),
        .C       (               ),
        .IOA_in  ( psg_ioa       ),
        .IOA_out (               ),
        .IOB_in  ( 8'hFF         ),
        .IOB_out ( psg_iob       )
    );

    //--------------------------------------------------------------------------
    // SLOTS (cartridge slots 1 and 2)
    //--------------------------------------------------------------------------
    wire  [7:0] d_from_slots;
    wire [15:0] sound_slots;
    wire  [3:0] active_mapper_A;
    wire  [7:0] stream_sum_A;
    wire [24:0] rom_size_A;
    wire  [7:0] slots_sdram_din;
    wire [24:0] slots_sdram_addr;
    wire        slots_sdram_we, slots_sdram_rd;
    wire        slots_ioctl_wait;

    // stall the bridge while the hash engine compresses a block and pace
    // the database download by SDRAM readiness, like cart downloads
    assign ioctl_wait = slots_ioctl_wait | sha1_busy
                      | (ioctl_isMAPDB & ~sdram_ready);

    //--------------------------------------------------------------------------
    // SDRAM readback verifier (diagnostic)
    //
    // After every reset release, re-read the slot A ROM image out of SDRAM
    // and sum it, holding the machine in reset meanwhile. Compared against
    // the download-stream checksum this splits 'the bytes never arrived'
    // from 'SDRAM lost them' without a logic analyser.
    //--------------------------------------------------------------------------
    reg  [24:0] v_addr;
    reg   [7:0] verify_sum;
    reg         verifying;
    reg   [2:0] v_state;
    reg   [3:0] v_wait;
    reg         v_rd;

    localparam SDRAM_VERIFY = 0;

    always @(posedge clk) begin
        v_rd <= 0;
        if (SDRAM_VERIFY && reset_i_d & ~reset_i && rom_size_A != 0) begin
            verifying  <= 1;
            v_addr     <= 0;
            verify_sum <= 0;
            v_state    <= 0;
        end
        else if (verifying) begin
            case (v_state)
                3'd0: begin v_rd <= 1; v_state <= 3'd1; v_wait <= 0; end
                3'd1: begin
                    // let the registered ready fall, then wait for data
                    v_wait <= v_wait + 1'd1;
                    if (v_wait == 4'd5) v_state <= 3'd2;
                end
                3'd2: if (sdram_ready) begin
                    verify_sum <= verify_sum + sdram_dout;
                    if (v_addr == rom_size_A - 1'd1) begin
                        verifying <= 0;
                    end
                    else begin
                        v_addr  <= v_addr + 1'd1;
                        v_state <= 3'd0;
                    end
                end
                default: v_state <= 3'd0;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Mapper database autodetect (see rtl/mapper_db.v). The machine is held
    // in reset while a lookup scans SDRAM, like the VRAM wipe.
    //--------------------------------------------------------------------------
    wire        db_scanning, db_pending, sha1_busy, db_rd;
    wire [24:0] db_addr;
    wire  [3:0] db_mapper_A, db_mapper_B;
    wire        db_valid_A, db_valid_B;
    wire        db_loaded_o;
    wire  [7:0] db_status = {db_loaded_o, 2'b00, db_valid_A, db_mapper_A};

    mapper_db mapper_db
    (
        .clk           ( clk           ),
        .ioctl_wr      ( ioctl_wr      ),
        .ioctl_addr    ( ioctl_addr    ),
        .ioctl_dout    ( ioctl_dout    ),
        .ioctl_isROMA  ( ioctl_isROMA  ),
        .ioctl_isROMB  ( ioctl_isROMB  ),
        .ioctl_isMAPDB ( ioctl_isMAPDB ),
        // the readback verifier (diag builds) owns the SDRAM mux with
        // higher priority at exactly reset-release; scanning then would
        // read cart bytes as table entries and miss every key
        .hold          ( verifying     ),
        .stall         ( sha1_busy     ),
        .scanning      ( db_scanning   ),
        .db_addr       ( db_addr       ),
        .db_rd         ( db_rd         ),
        .sdram_dout    ( sdram_dout    ),
        .sdram_ready   ( sdram_ready   ),
        .db_mapper_A   ( db_mapper_A   ),
        .db_valid_A    ( db_valid_A    ),
        .db_mapper_B   ( db_mapper_B   ),
        .db_valid_B    ( db_valid_B    ),
        .db_loaded_o   ( db_loaded_o   ),
        .db_pending    ( db_pending    )
    );

    wire mapram_access = mapram_rd | mapram_wr;

    assign sdram_addr = verifying      ? {3'b001, v_addr[21:0]}     :
                        ioctl_isMAPDB  ? {3'b010, ioctl_addr[21:0]} :
                        db_scanning    ? {3'b010, db_addr[21:0]}    :
                        mapram_access  ? mapram_addr                :
                                         slots_sdram_addr;
    assign sdram_din  = ioctl_isMAPDB ? ioctl_dout :
                        mapram_wr     ? d_from_cpu : slots_sdram_din;
    assign sdram_we   = ioctl_isMAPDB ? ioctl_wr :
                        (verifying | db_scanning) ? 1'b0 :
                        mapram_wr ? 1'b1 : slots_sdram_we;
    assign sdram_rd   = verifying   ? v_rd  :
                        db_scanning ? db_rd :
                        ioctl_isMAPDB ? 1'b0 :
                        mapram_rd   ? 1'b1  : slots_sdram_rd;

    slots #(.INTERNAL_RAM(0), .USE_FDD(0)) slots
    (
        .clk           ( clk           ),
        .clk_en        ( clk_en_3m58_p ),
        .reset         ( reset         ),
        .addr          ( a             ),
        .wr_n          ( wr_n          ),
        .rd_n          ( rd_n          ),
        .CS1_n         ( CS1_n         ),
        .CS2_n         ( CS2_n         ),
        .CS12_n        ( CS12_n        ),
        .SLTSL_n       ( SLTSL_n       ),
        .d_from_cpu    ( d_from_cpu    ),
        .d_to_cpu      ( d_from_slots  ),
        .sound         ( sound_slots   ),
        .active_mapper_A ( active_mapper_A ),
        .stream_sum_A  ( stream_sum_A  ),
        .rom_size_A    ( rom_size_A    ),
        .ioctl_wr      ( ioctl_wr      ),
        .ioctl_addr    ( ioctl_addr    ),
        .ioctl_dout    ( ioctl_dout    ),
        .ioctl_isROMA  ( ioctl_isROMA  ),
        .ioctl_isROMB  ( ioctl_isROMB  ),
        .ioctl_wait    ( slots_ioctl_wait ),
        .sdram_dout    ( sdram_dout      ),
        .sdram_din     ( slots_sdram_din ),
        .sdram_addr    ( slots_sdram_addr),
        .sdram_we      ( slots_sdram_we  ),
        .sdram_rd      ( slots_sdram_rd  ),
        .sdram_ready   ( sdram_ready     ),
        .sdram_size    ( sdram_size    ),
        .slot_A        ( slot_A        ),
        .slot_B        ( slot_B        ),
        .db_mapper_A   ( db_mapper_A   ),
        .db_valid_A    ( db_valid_A    ),
        .db_mapper_B   ( db_mapper_B   ),
        .db_valid_B    ( db_valid_B    ),
        .mapper_info   ( mapper_info   ),
        .rom_enabled   ( rom_enabled   ),
        .img_mounted   ( img_mounted   ),
        .img_size      ( img_size      ),
        .img_wp        ( img_wp        ),
        .sd_lba        ( sd_lba        ),
        .sd_rd         ( sd_rd         ),
        .sd_wr         ( sd_wr         ),
        .sd_ack        ( sd_ack        ),
        .sd_buff_addr  ( sd_buff_addr  ),
        .sd_buff_dout  ( sd_buff_dout  ),
        .sd_buff_din   ( sd_buff_din   ),
        .sd_buff_wr    ( sd_buff_wr    ),
        .sd_din_strobe ( sd_din_strobe )
    );

endmodule
