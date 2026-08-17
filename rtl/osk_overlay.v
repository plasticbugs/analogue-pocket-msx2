//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// On-screen keyboard overlay: draws the pre-rendered keyboard panel
// (tools/make_osk_panel.py -> rtl/rom/osk_panel.mif) over the picture,
// toggled by a controller chord, with a d-pad-driven key highlight.
//
// The panel is 240x72 at one bit per pixel, addressed in panel-pixel space
// (four machine clocks per panel pixel: the DE line is ~1192 clk21 = 596
// output samples at 10.74MHz), centred horizontally above the bottom border.
//
// The key grid is 12 columns x 6 rows of 20x12 cells; the only multi-cell
// key is SPACE on the bottom row (columns 3..7). The cursor starts on ESC
// whenever the panel is shown, moves with the d-pad (wrapping, with
// hold-to-repeat), and renders as an inverted cell: white background,
// dark glyph.
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
        input             frame,     // one-clock pulse per frame (vsync edge)
        input             up,
        input             down,
        input             left,
        input             right,
        input             vdp_pal,
        input       [8:0] line,      // visible-line counter
        input      [10:0] xcnt,      // machine-clock counter within the DE line
        output     [11:0] rom_addr,
        input       [7:0] rom_q,
        output            visible,   // panel is up: host masks d-pad from game
        output            active,    // overlay owns this pixel
        output            pix,       // 1 = white pixel
        output            dark       // 1 = black pixel (highlighted glyph)
    );

    localparam [8:0] PANEL_W = 9'd240;
    localparam [8:0] PANEL_H = 9'd72;
    localparam [8:0] X0      = 9'd29;   // centres 240 px in the ~298 px line

    //--------------------------------------------------------------------------
    // Chord toggle: one flip per press, re-arm on release
    //--------------------------------------------------------------------------
    reg chord_d = 1'b0;
    reg en      = 1'b0;

    //--------------------------------------------------------------------------
    // Cursor: (row, col) into the 12x6 cell grid. SPACE (row 5, cols 3..7)
    // is one key: the span functions collapse it for movement and highlight.
    //--------------------------------------------------------------------------
    reg [2:0] cur_row = 3'd0;
    reg [3:0] cur_col = 4'd0;

    function [3:0] key_start(input [2:0] row, input [3:0] col);
        key_start = (row == 3'd5 && col >= 4'd3 && col <= 4'd7) ? 4'd3 : col;
    endfunction
    function [3:0] key_span(input [2:0] row, input [3:0] col);
        key_span = (row == 3'd5 && col >= 4'd3 && col <= 4'd7) ? 4'd5 : 4'd1;
    endfunction

    wire [3:0] k_start = key_start(cur_row, cur_col);
    wire [3:0] k_span  = key_span (cur_row, cur_col);

    // hold-to-repeat: move immediately on press, then after ~1/3s repeat
    // every 5 frames
    localparam [4:0] RPT_DELAY = 5'd20;
    localparam [4:0] RPT_BACK  = 5'd16;

    reg [4:0] rpt = 5'd0;
    wire dir_any = up | down | left | right;
    wire step    = frame & dir_any & ((rpt == 5'd0) | (rpt >= RPT_DELAY));

    always @(posedge clk) begin
        chord_d <= chord;
        if (chord & ~chord_d) begin
            en <= ~en;
            if (~en) begin              // showing: home the cursor
                cur_row <= 3'd0;
                cur_col <= 4'd0;
            end
        end

        if (frame) begin
            if (!dir_any)  rpt <= 5'd0;
            else           rpt <= (rpt >= RPT_DELAY) ? RPT_BACK : rpt + 5'd1;
        end

        if (en & step) begin
            if (up)         cur_row <= (cur_row == 3'd0) ? 3'd5 : cur_row - 3'd1;
            else if (down)  cur_row <= (cur_row == 3'd5) ? 3'd0 : cur_row + 3'd1;
            else if (left)  cur_col <= (k_start == 4'd0) ? 4'd11 : k_start - 4'd1;
            else if (right) cur_col <= (k_start + k_span > 4'd11) ? 4'd0
                                                                  : k_start + k_span;
        end
    end

    //--------------------------------------------------------------------------
    // Panel window in panel-pixel coordinates
    //--------------------------------------------------------------------------
    wire [8:0] y0 = vdp_pal ? 9'd192 : 9'd156;

    wire [8:0] px = xcnt[10:2];         // 4 clk21 per panel pixel
    wire [8:0] rx = px - X0;
    wire [8:0] ry = line - y0;
    wire       inp = (px >= X0) && (rx < PANEL_W) &&
                     (line >= y0) && (ry < PANEL_H);

    // highlight window: cell x20 horizontally, x12 vertically
    wire [8:0] hl_x0 = {3'b000, k_start, 2'b00} + {1'b0, k_start, 4'b0000};
    wire [8:0] hl_x1 = hl_x0 + ({3'b000, k_span, 2'b00} + {1'b0, k_span, 4'b0000});
    wire [8:0] hl_y0 = {4'b0000, cur_row, 2'b00} + {3'b000, cur_row, 3'b000};
    wire       in_hl = inp && (rx >= hl_x0) && (rx < hl_x1) &&
                       (ry >= hl_y0) && (ry < hl_y0 + 9'd12);

    // ry * 30 = ry*32 - ry*2
    wire [11:0] row_base = {ry[6:0], 5'b00000} - {2'b00, ry[6:0], 1'b0};

    assign rom_addr = row_base + {7'b0, rx[7:3]};

    // rom_q is registered in the BRAM: align the bit select and the window
    // flags with data fetched one clock earlier
    reg [2:0] bit_d;
    reg       inp_d, hl_d;
    always @(posedge clk) begin
        bit_d <= rx[2:0];
        inp_d <= inp;
        hl_d  <= in_hl;
    end

    wire rom_bit = rom_q[3'd7 - bit_d];

    assign visible = en;
    assign active  = en & inp_d;
    assign pix     = rom_bit ^ hl_d;    // highlight inverts the cell
    assign dark    = rom_bit & hl_d;    // glyph inside the highlight is black

endmodule
