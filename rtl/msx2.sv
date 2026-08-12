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
        input         reset,
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
        output        ioctl_wait,
        // Cassette
        output        cas_motor,
        input         cas_audio_in,
        // User Mode
        input   [1:0] rom_enabled,
        input   [3:0] slot_A,
        input   [3:0] slot_B,
        output  [2:0] mapper_info,
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
    // Audio MIX
    //--------------------------------------------------------------------------
    wire  [9:0] audioPSG   = ay_ch_mix + {keybeep, 5'b00000} + {(cas_audio_in & ~cas_motor), 4'b0000};
    wire [15:0] fm         = {2'b0, audioPSG, 4'b0000};
    wire [16:0] audio_mix  = {sound_slots[15], sound_slots} + {fm[15], fm};
    wire [15:0] compr[7:0] = '{{1'b1, audio_mix[13:0], 1'b0}, 16'h8000, 16'h8000, 16'h8000, 16'h7FFF, 16'h7FFF, 16'h7FFF,  {1'b0, audio_mix[13:0], 1'b0}};

    assign audio = compr[audio_mix[16:14]];

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

    t80pa #(.Mode(0)) u_t80
    (
        .RESET_n ( ~reset        ),
        .CLK     ( clk           ),
        .CEN_p   ( clk_en_3m58_p ),
        .CEN_n   ( clk_en_3m58_n ),
        .WAIT_n  ( wait_n        ),
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
    //--------------------------------------------------------------------------
    reg  iack;
    wire req = ((~mreq_n | ~iorq_n) & (~rd_n | ~wr_n) & ~iack);

    always @(posedge clk) begin
        if (reset) begin
            iack <= 0;
        end
        else begin
            if (mreq_n & iorq_n) begin
                iack <= 0;
            end
            else if (req) begin
                iack <= 1;
            end
        end
    end

    wire io_en    = ~iorq_n & m1_n;
    wire vdp_sel  = io_en & (a[7:2] == 6'b100110);  // 98-9B
    wire rtc_sel  = io_en & (a[7:1] == 7'b1011010); // B4-B5
    wire map_sel  = io_en & (a[7:2] == 6'b111111);  // FC-FF

    wire vdp_req  = req & vdp_sel;
    wire rtc_req  = req & rtc_sel;

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
        .clock   ( clk       ),
        .address ( a[13:0]   ),
        .q       ( sub_rom_q ),
        .wren    ( 0         ),
        .data    ( 8'h0      )
    );

    //--------------------------------------------------------------------------
    // Video RAM 128k (two 64k banks side by side on a 16bit read bus,
    // bank selected by address bit 16)
    //--------------------------------------------------------------------------
    wire [16:0] vdp_pram_a;
    wire  [7:0] vdp_pram_do;
    wire        vdp_pramwe_n;
    wire  [7:0] vram0_q, vram1_q;

    spram #(.addr_width(16), .mem_name("VRAM0")) vram0
    (
        .clock   ( clk                             ),
        .address ( vdp_pram_a[15:0]                ),
        .wren    ( ~vdp_pramwe_n & ~vdp_pram_a[16] ),
        .data    ( vdp_pram_do                     ),
        .q       ( vram0_q                         )
    );

    spram #(.addr_width(16), .mem_name("VRAM1")) vram1
    (
        .clock   ( clk                             ),
        .address ( vdp_pram_a[15:0]                ),
        .wren    ( ~vdp_pramwe_n & vdp_pram_a[16]  ),
        .data    ( vdp_pram_do                     ),
        .q       ( vram1_q                         )
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
        .WRT             ( ~wr_n         ),
        .ADR             ( a             ),
        .DBI             ( d_from_vdp    ),
        .DBO             ( d_from_cpu    ),

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
        .PVIDEODE        ( video_de      ),

        .PVIDEOHS_N      ( hsync_n       ),
        .PVIDEOVS_N      ( vsync_n       ),
        .PVIDEOCS_N      (               ),

        .PVIDEODHCLK     (               ),
        .PVIDEODLCLK     (               ),

        .DISPRESO        ( 1'b0          ), // 15kHz
        .NTSC_PAL_TYPE   ( ~vdp_pal      ), // 1: follow VDP R9 PAL bit, 0: forced
        .FORCED_V_MODE   ( vdp_pal       ),
        .LEGACY_VGA      ( 1'b0          )
    );

    assign R = {vdp_r, vdp_r[5:4]};
    assign G = {vdp_g, vdp_g[5:4]};
    assign B = {vdp_b, vdp_b[5:4]};

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
        .wrt    ( ~wr_n       ),
        .adr    ( a           ),
        .dbi    ( d_from_rtc  ),
        .dbo    ( d_from_cpu  )
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
    // Slot 3-2: Memory mapper RAM, 64kB (4 segments of 16kB), I/O FC-FF
    // (64kB is the MSX2 minimum; segments alias above that, as on real
    // small-mapper machines. Sized to fit the Pocket's block RAM.)
    //--------------------------------------------------------------------------
    // Only SEG_BITS of each segment register are implemented. The unimplemented
    // bits must read back as 1, because software sizes the mapper by writing a
    // segment number and reading it back: storing all 8 bits would advertise
    // 256 segments (4MB) while only SEG_BITS worth of RAM exists, and every
    // access above that would silently alias onto memory already in use.
    localparam SEG_BITS = 2; // 4 segments x 16kB = 64kB

    reg  [7:0] map_reg[3:0];
    wire [7:0] map_q;
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

    spram #(.addr_width(SEG_BITS+14), .mem_name("MAPRAM")) map_ram
    (
        .clock   ( clk                        ),
        .address ( {map_seg, a[13:0]}         ),
        .q       ( map_q                      ),
        .data    ( d_from_cpu                 ),
        .wren    ( sltsl32 & ~wr_n            )
    );

    //--------------------------------------------------------------------------
    // CPU data multiplex
    //--------------------------------------------------------------------------
    assign d_to_cpu = ~(CS01_n | SLTSL_n[0]) ? rom_q          :
                      ~(CS2_n  | SLTSL_n[0]) ? fw_rom_q       :
                      ~(SLTSL_n[1])          ? d_from_slots   :
                      ~(SLTSL_n[2])          ? d_from_slots   :
                      (exp3_sel & ~rd_n)     ? ~exp3_reg      :
                      (sub_rom_en & ~rd_n)   ? sub_rom_q      :
                      (sltsl32 & ~rd_n)      ? map_q          :
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
        .ioctl_wr      ( ioctl_wr      ),
        .ioctl_addr    ( ioctl_addr    ),
        .ioctl_dout    ( ioctl_dout    ),
        .ioctl_isROMA  ( ioctl_isROMA  ),
        .ioctl_isROMB  ( ioctl_isROMB  ),
        .ioctl_wait    ( ioctl_wait    ),
        .sdram_dout    ( sdram_dout    ),
        .sdram_din     ( sdram_din     ),
        .sdram_addr    ( sdram_addr    ),
        .sdram_we      ( sdram_we      ),
        .sdram_rd      ( sdram_rd      ),
        .sdram_ready   ( sdram_ready   ),
        .sdram_size    ( sdram_size    ),
        .slot_A        ( slot_A        ),
        .slot_B        ( slot_B        ),
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
