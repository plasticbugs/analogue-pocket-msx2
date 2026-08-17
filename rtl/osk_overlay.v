//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// On-screen keyboard overlay: draws the pre-rendered keyboard panel
// (tools/make_osk_panel.py -> rtl/rom/osk_panel.mif) over the picture,
// with a d-pad-driven key highlight, A/B keypress injection, and a CAP
// shift-lock.
//
// Two chords: L+R+Select shows the Japanese layout, L+R+Start the
// International one. The same chord dismisses; the other chord switches
// layout in place. The layouts share key geometry and scancodes -- both
// address the same key-matrix positions, and the loaded BIOS decides what
// each position types -- except the JIS underscore key, which exists only
// on the Japanese layout (International keeps a wider right SHIFT there).
//
// The panel ROM holds four 240x72 1bpp pages (layout x shift-lock),
// selected by rom_addr[13:12]. Panel pixels are four machine clocks wide
// (the DE line is ~1192 clk21 = 596 output samples at 10.74MHz); the grid
// is 15 columns x 6 rows of 16x12 cells with multi-cell keys.
//
// The bitmap ROM lives outside this module (spram in msx2.sv) so the logic
// stays simulable with iverilog alone: present rom_addr, expect rom_q one
// clock later.
//
//------------------------------------------------------------------------------

module osk_overlay
    (
        input             clk,
        input             chord,     // L+R+Select: Japanese layout / dismiss
        input             chord2,    // L+R+Start: International layout / dismiss
        input             frame,     // one-clock pulse per frame (vsync edge)
        input             up,
        input             down,
        input             left,
        input             right,
        input             press,     // A or B: type the highlighted key
        input             vdp_pal,
        input       [8:0] line,      // visible-line counter
        input      [10:0] xcnt,      // machine-clock counter within the DE line
        output     [13:0] rom_addr,
        input       [7:0] rom_q,
        output reg [10:0] key_ev = 11'd0,  // PS/2 event stream, OR-merged by host
        output            visible,   // panel is up: host masks the pad from game
        output            active,    // overlay owns this pixel
        output            pix,       // 1 = white pixel
        output            dark       // 1 = black pixel (highlighted glyph)
    );

    localparam [8:0] PANEL_W = 9'd240;
    localparam [8:0] PANEL_H = 9'd72;
    localparam [8:0] X0      = 9'd29;   // centres 240 px in the ~298 px line

    localparam LAY_JP = 1'b0, LAY_INTL = 1'b1;

    //--------------------------------------------------------------------------
    // Chords: show with the chord's layout, dismiss on the same chord,
    // switch layout in place on the other. One action per press.
    //--------------------------------------------------------------------------
    reg chord_d  = 1'b0;
    reg chord2_d = 1'b0;
    reg en       = 1'b0;
    reg layout   = LAY_JP;

    //--------------------------------------------------------------------------
    // Cursor: (row, col) into the 15x6 cell grid, with multi-cell keys
    // resolved by the span functions. Only row 4 differs between layouts
    // (the JIS underscore key).
    //--------------------------------------------------------------------------
    reg [2:0] cur_row = 3'd0;
    reg [3:0] cur_col = 4'd0;

    function [3:0] key_start(input [2:0] row, input [3:0] col, input lay);
        case (row)
            3'd0: key_start = (col < 4'd6)  ? col :
                              (col < 4'd14) ? {col[3:1], 1'b0} : 4'd14;
            3'd1: key_start = (col < 4'd13) ? col : 4'd13;
            3'd2: key_start = (col < 4'd10) ? col :
                              (col < 4'd12) ? 4'd10 : 4'd12;
            3'd3: key_start = (col < 4'd12) ? col : 4'd12;
            3'd4: key_start = (col < 4'd2)  ? 4'd0 :
                              (col < 4'd12) ? col :
                              (lay == LAY_JP && col == 4'd12) ? 4'd12 :
                              (lay == LAY_JP) ? 4'd13 : 4'd12;
            3'd5: key_start = (col < 4'd6)  ? {col[3:1], 1'b0} :
                              (col < 4'd12) ? 4'd6 : 4'd12;
            default: key_start = col;
        endcase
    endfunction

    function [3:0] key_span(input [2:0] row, input [3:0] col, input lay);
        case (row)
            3'd0: key_span = (col < 4'd6) ? 4'd1 : (col < 4'd14) ? 4'd2 : 4'd1;
            3'd1: key_span = (col < 4'd13) ? 4'd1 : 4'd2;
            3'd2: key_span = (col < 4'd10) ? 4'd1 : (col < 4'd12) ? 4'd2 : 4'd3;
            3'd3: key_span = (col < 4'd12) ? 4'd1 : 4'd3;
            3'd4: key_span = (col < 4'd2)  ? 4'd2 :
                             (col < 4'd12) ? 4'd1 :
                             (lay == LAY_JP && col == 4'd12) ? 4'd1 :
                             (lay == LAY_JP) ? 4'd2 : 4'd3;
            3'd5: key_span = (col < 4'd6) ? 4'd2 : (col < 4'd12) ? 4'd6 : 4'd3;
            default: key_span = 4'd1;
        endcase
    endfunction

    wire [3:0] k_start = key_start(cur_row, cur_col, layout);
    wire [3:0] k_span  = key_span (cur_row, cur_col, layout);

    // hold-to-repeat: move immediately on press, then after ~1/3s repeat
    // every 5 frames
    localparam [4:0] RPT_DELAY = 5'd20;
    localparam [4:0] RPT_BACK  = 5'd16;

    reg [4:0] rpt = 5'd0;
    wire dir_any = up | down | left | right;
    wire step    = frame & dir_any & ((rpt == 5'd0) | (rpt >= RPT_DELAY));

    always @(posedge clk) begin
        chord_d  <= chord;
        chord2_d <= chord2;
        if (chord & ~chord_d) begin
            if (!en) begin
                en      <= 1'b1;
                layout  <= LAY_JP;
                cur_row <= 3'd0;
                cur_col <= 4'd0;
            end
            else if (layout == LAY_JP) en <= 1'b0;
            else layout <= LAY_JP;
        end
        else if (chord2 & ~chord2_d) begin
            if (!en) begin
                en      <= 1'b1;
                layout  <= LAY_INTL;
                cur_row <= 3'd0;
                cur_col <= 4'd0;
            end
            else if (layout == LAY_INTL) en <= 1'b0;
            else layout <= LAY_INTL;
        end

        if (frame) begin
            if (!dir_any)  rpt <= 5'd0;
            else           rpt <= (rpt >= RPT_DELAY) ? RPT_BACK : rpt + 5'd1;
        end

        if (en & step) begin
            if (up)         cur_row <= (cur_row == 3'd0) ? 3'd5 : cur_row - 3'd1;
            else if (down)  cur_row <= (cur_row == 3'd5) ? 3'd0 : cur_row + 3'd1;
            else if (left)  cur_col <= (k_start == 4'd0) ? 4'd14 : k_start - 4'd1;
            else if (right) cur_col <= (k_start + k_span > 4'd14) ? 4'd0
                                                                  : k_start + k_span;
        end
    end

    //--------------------------------------------------------------------------
    // Key press injection: on an A/B press edge, emit one PS/2 make event for
    // the highlighted key, hold it three frames, then the break. One event
    // per press -- holding the button does not repeat. Event protocol matches
    // joy2ps2: [10] strobe (consumers react to its change), [9] pressed,
    // [8] extended, [7:0] scancode; all-zeros when idle.
    //
    // Scancodes address key-matrix positions (rtl/keyboard.vhd's map, checked
    // key by key, extended codes included); the loaded BIOS decides what each
    // position types, so the table is shared by both layouts. The single
    // layout-specific spot is row 4 col 12+: the JIS underscore key (PS/2
    // 0x01 -> matrix (2)(5)) vs the International right SHIFT.
    //--------------------------------------------------------------------------
    function [8:0] osk_sc(input [2:0] row, input [3:0] col, input lay);
        case ({row, col})
            {3'd0, 4'd0}:  osk_sc = 9'h076;  // ESC
            {3'd0, 4'd1}:  osk_sc = 9'h005;  // F1
            {3'd0, 4'd2}:  osk_sc = 9'h006;  // F2
            {3'd0, 4'd3}:  osk_sc = 9'h004;  // F3
            {3'd0, 4'd4}:  osk_sc = 9'h00C;  // F4
            {3'd0, 4'd5}:  osk_sc = 9'h003;  // F5
            {3'd0, 4'd6}:  osk_sc = 9'h17C;  // STOP
            {3'd0, 4'd8}:  osk_sc = 9'h16C;  // HOME
            {3'd0, 4'd10}: osk_sc = 9'h170;  // INS
            {3'd0, 4'd12}: osk_sc = 9'h171;  // DEL
            {3'd0, 4'd14}: osk_sc = 9'h00D;  // TAB
            {3'd1, 4'd0}:  osk_sc = 9'h016;  // 1
            {3'd1, 4'd1}:  osk_sc = 9'h01E;  // 2
            {3'd1, 4'd2}:  osk_sc = 9'h026;  // 3
            {3'd1, 4'd3}:  osk_sc = 9'h025;  // 4
            {3'd1, 4'd4}:  osk_sc = 9'h02E;  // 5
            {3'd1, 4'd5}:  osk_sc = 9'h036;  // 6
            {3'd1, 4'd6}:  osk_sc = 9'h03D;  // 7
            {3'd1, 4'd7}:  osk_sc = 9'h03E;  // 8
            {3'd1, 4'd8}:  osk_sc = 9'h046;  // 9
            {3'd1, 4'd9}:  osk_sc = 9'h045;  // 0
            {3'd1, 4'd10}: osk_sc = 9'h04E;  // - =        (JP legends)
            {3'd1, 4'd11}: osk_sc = 9'h055;  // ^ ~ / = +
            {3'd1, 4'd12}: osk_sc = 9'h05D;  // yen |  / \ |
            {3'd1, 4'd13}: osk_sc = 9'h066;  // BS
            {3'd2, 4'd0}:  osk_sc = 9'h015;  // Q
            {3'd2, 4'd1}:  osk_sc = 9'h01D;  // W
            {3'd2, 4'd2}:  osk_sc = 9'h024;  // E
            {3'd2, 4'd3}:  osk_sc = 9'h02D;  // R
            {3'd2, 4'd4}:  osk_sc = 9'h02C;  // T
            {3'd2, 4'd5}:  osk_sc = 9'h035;  // Y
            {3'd2, 4'd6}:  osk_sc = 9'h03C;  // U
            {3'd2, 4'd7}:  osk_sc = 9'h043;  // I
            {3'd2, 4'd8}:  osk_sc = 9'h044;  // O
            {3'd2, 4'd9}:  osk_sc = 9'h04D;  // P
            {3'd2, 4'd10}: osk_sc = 9'h054;  // @ ` / [ {
            {3'd2, 4'd12}: osk_sc = 9'h05B;  // [ { / ] }
            {3'd3, 4'd0}:  osk_sc = 9'h01C;  // A
            {3'd3, 4'd1}:  osk_sc = 9'h01B;  // S
            {3'd3, 4'd2}:  osk_sc = 9'h023;  // D
            {3'd3, 4'd3}:  osk_sc = 9'h02B;  // F
            {3'd3, 4'd4}:  osk_sc = 9'h034;  // G
            {3'd3, 4'd5}:  osk_sc = 9'h033;  // H
            {3'd3, 4'd6}:  osk_sc = 9'h03B;  // J
            {3'd3, 4'd7}:  osk_sc = 9'h042;  // K
            {3'd3, 4'd8}:  osk_sc = 9'h04B;  // L
            {3'd3, 4'd9}:  osk_sc = 9'h04C;  // ; +
            {3'd3, 4'd10}: osk_sc = 9'h052;  // : * / ' "
            {3'd3, 4'd11}: osk_sc = 9'h00E;  // ] } / ` ~
            {3'd3, 4'd12}: osk_sc = 9'h05A;  // RET
            {3'd4, 4'd0}:  osk_sc = 9'h012;  // SHF
            {3'd4, 4'd2}:  osk_sc = 9'h01A;  // Z
            {3'd4, 4'd3}:  osk_sc = 9'h022;  // X
            {3'd4, 4'd4}:  osk_sc = 9'h021;  // C
            {3'd4, 4'd5}:  osk_sc = 9'h02A;  // V
            {3'd4, 4'd6}:  osk_sc = 9'h032;  // B
            {3'd4, 4'd7}:  osk_sc = 9'h031;  // N
            {3'd4, 4'd8}:  osk_sc = 9'h03A;  // M
            {3'd4, 4'd9}:  osk_sc = 9'h041;  // ,  <
            {3'd4, 4'd10}: osk_sc = 9'h049;  // .  >
            {3'd4, 4'd11}: osk_sc = 9'h04A;  // /  ?
            {3'd4, 4'd12}: osk_sc = (lay == LAY_JP) ? 9'h001   // JIS underscore
                                                    : 9'h012;  // SHF
            {3'd4, 4'd13}: osk_sc = 9'h012;  // SHF
            {3'd5, 4'd0}:  osk_sc = 9'h012;  // CAP (shift-lock, see FSM)
            {3'd5, 4'd2}:  osk_sc = 9'h014;  // CTL
            {3'd5, 4'd4}:  osk_sc = 9'h111;  // GRP
            {3'd5, 4'd6}:  osk_sc = 9'h029;  // SPACE
            {3'd5, 4'd12}: osk_sc = 9'h009;  // COD
            default: osk_sc = 9'h000;
        endcase
    endfunction

    localparam K_IDLE = 2'd0, K_MAKE = 2'd1, K_BRK = 2'd2;

    reg [1:0] kstate     = K_IDLE;
    reg [1:0] kcnt       = 2'd0;
    reg       press_d    = 1'b0;
    reg       shlock     = 1'b0;   // CAP engaged: SHIFT held in the matrix
    reg       pend_shbrk = 1'b0;   // release SHIFT after a mid-lock dismiss
    reg       en_d       = 1'b0;

    wire       cap_key = (cur_row == 3'd5) && (k_start == 4'd0);
    wire [8:0] cur_sc  = osk_sc(cur_row, k_start, layout);
    wire       typing  = (kstate != K_IDLE);

    // Every event toggles the strobe with its payload; returning to the
    // all-zeros idle from a high strobe emits a break of scancode 0, which
    // maps to nothing in keyboard.vhd -- so a held SHIFT survives the
    // stream idling between keys.
    always @(posedge clk) begin
        press_d <= press;
        en_d    <= en;
        if (en_d & ~en & shlock) begin       // dismissed with the lock on
            shlock     <= 1'b0;
            pend_shbrk <= 1'b1;
        end
        case (kstate)
            K_IDLE: begin
                if (pend_shbrk) begin
                    key_ev     <= {~key_ev[10], 1'b0, 9'h012};
                    pend_shbrk <= 1'b0;
                    kstate     <= K_BRK;
                end
                else if (en & press & ~press_d) begin
                    if (cap_key) begin       // toggle the lock: one shift event
                        key_ev <= {~key_ev[10], ~shlock, 9'h012};
                        shlock <= ~shlock;
                        kstate <= K_BRK;
                    end
                    else if (cur_sc != 9'd0) begin
                        key_ev <= {~key_ev[10], 1'b1, cur_sc};
                        kstate <= K_MAKE;
                        kcnt   <= 2'd0;
                    end
                end
            end
            K_MAKE: if (frame) begin
                kcnt <= kcnt + 2'd1;
                if (kcnt == 2'd2) begin
                    key_ev <= {~key_ev[10], 1'b0, key_ev[8:0]};  // break
                    kstate <= K_BRK;
                    kcnt   <= 2'd0;
                end
            end
            K_BRK: if (frame) begin
                key_ev <= 11'd0;
                kstate <= K_IDLE;
            end
            default: kstate <= K_IDLE;
        endcase
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

    // highlight window: cell x16 horizontally, x12 vertically
    wire [8:0] hl_x0 = {1'b0, k_start, 4'b0000};
    wire [8:0] hl_x1 = hl_x0 + {1'b0, k_span, 4'b0000};
    wire [8:0] hl_y0 = {4'b0000, cur_row, 2'b00} + {3'b000, cur_row, 3'b000};
    wire       in_hl = inp && (rx >= hl_x0) && (rx < hl_x1) &&
                       (ry >= hl_y0) && (ry < hl_y0 + 9'd12);

    // the CAP key cell (2 cells wide) stays inverted while the lock is engaged
    wire in_cap = inp && (rx < 9'd32) && (ry >= 9'd60);

    // ry * 30 = ry*32 - ry*2
    wire [11:0] row_base = {ry[6:0], 5'b00000} - {2'b00, ry[6:0], 1'b0};

    assign rom_addr = {layout, shlock, row_base + {7'b0, rx[7:3]}};

    // rom_q is registered in the BRAM: align the bit select and the window
    // flags with data fetched one clock earlier
    reg [2:0] bit_d;
    reg       inp_d, hl_d, cap_d;
    always @(posedge clk) begin
        bit_d <= rx[2:0];
        inp_d <= inp;
        hl_d  <= in_hl;
        cap_d <= in_cap;
    end

    wire rom_bit = rom_q[3'd7 - bit_d];

    // while a keypress is being injected the inversion is suppressed, so the
    // highlighted key visibly flashes for the make+break window
    wire inv = (hl_d & ~typing) | (shlock & cap_d);

    assign visible = en;
    assign active  = en & inp_d;
    assign pix     = rom_bit ^ inv;     // highlight inverts the cell
    assign dark    = rom_bit & inv;     // glyph inside the highlight is black

endmodule
