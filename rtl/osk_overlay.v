//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// On-screen keyboard overlay, milestone 1: draw the pre-rendered keyboard
// panel (tools/make_osk_panel.py -> rtl/rom/osk_panel.mif) over the picture,
// toggled by a controller chord. The panel is 240x72 at one bit per pixel,
// addressed in panel-pixel space (four machine clocks per panel pixel:
// the DE line is ~1192 clk21 = 596 output samples at 10.74MHz), centred
// horizontally and sitting above the bottom border.
//
// The bitmap ROM lives outside this module (spram in msx2.sv) so the logic
// stays simulable with iverilog alone: present rom_addr, expect rom_q one
// clock later.
//
//------------------------------------------------------------------------------

module osk_overlay
    (
        input             clk,
        input             chord,     // toggle input, synchronous to clk
        input             vdp_pal,
        input       [8:0] line,      // visible-line counter
        input      [10:0] xcnt,      // output-sample counter within the DE line
        output     [11:0] rom_addr,
        input       [7:0] rom_q,
        output            active,    // overlay owns this pixel
        output            pix        // 1 = glyph pixel, 0 = dimmed backdrop
    );

    localparam [8:0] PANEL_W = 9'd240;
    localparam [8:0] PANEL_H = 9'd72;
    localparam [8:0] X0      = 9'd29;   // centres 240 px in the ~298 px line

    //--------------------------------------------------------------------------
    // Chord toggle: one flip per press, re-arm on release
    //--------------------------------------------------------------------------
    reg chord_d = 1'b0;
    reg en      = 1'b0;

    always @(posedge clk) begin
        chord_d <= chord;
        if (chord & ~chord_d) en <= ~en;
    end

    //--------------------------------------------------------------------------
    // Panel window in MSX-pixel coordinates
    //--------------------------------------------------------------------------
    wire [8:0] y0 = vdp_pal ? 9'd192 : 9'd156;

    wire [8:0] px = xcnt[10:2];         // 4 clk21 per panel pixel
    wire [8:0] rx = px - X0;
    wire [8:0] ry = line - y0;
    wire       inp = (px >= X0) && (rx < PANEL_W) &&
                     (line >= y0) && (ry < PANEL_H);

    // ry * 30 = ry*32 - ry*2
    wire [11:0] row_base = {ry[6:0], 5'b00000} - {2'b00, ry[6:0], 1'b0};

    assign rom_addr = row_base + {7'b0, rx[7:3]};

    // rom_q is registered in the BRAM: align the bit select and the window
    // flag with data fetched one clock earlier
    reg [2:0] bit_d;
    reg       inp_d;
    always @(posedge clk) begin
        bit_d <= rx[2:0];
        inp_d <= inp;
    end

    assign active = en & inp_d;
    assign pix    = rom_q[3'd7 - bit_d];

endmodule
