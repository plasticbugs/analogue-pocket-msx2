// Drive the Analogizer's scandoubler_2 with MSX-shaped video timing and
// check that it produces line-doubled output: two Hsync pulses and two
// output lines per input line, one Vsync per field, an Hblank that toggles
// every output line, and pixel data that reproduces each input line intact.
//
// The front end mirrors openFPGA_Pocket_Analogizer.v: syncs, blanks and RGB
// are sampled on the rising edge of ce_pix (the core's 10.74 MHz enable seen
// from the 42.95 MHz Analogizer clock), and RGB is masked by ~(HBL|VBL).
//
// Timing: 684 pixels per line at ce_pix, Hblank high for the first HB_W
// pixels with the Hsync pulse inside it; NTSC field of 262 lines with the
// first VB_L lines Vblank (the V9938's BWINDOW_X/BWINDOW_Y complement, as
// exported on PVIDEO_HBLANK/PVIDEO_VBLANK and measured by tb_blank.vhd).
//
//   $ verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH \
//       -GLENGTH=684 --top-module tb_scandoubler --Mdir obj -o sd \
//       sim/tb_scandoubler.v target/pocket/analogizer/scandoubler_2.v hq2x_vl.sv
//   ./obj/sd
// (hq2x_vl.sv is hq2x.sv with the Blend module's `output [23:0] Result`
// changed to `output reg`; Quartus accepts the procedural assignment to a
// wire, Verilator does not. iverilog cannot parse hq2x.sv at all.)
//
// LENGTH=290 (the value the Analogizer hook shipped with) shows the failure
// mode of an undersized line buffer; LENGTH=684 is the full MSX line.
`timescale 1ns/1ps
module tb_scandoubler;
    parameter LENGTH = 684;
    localparam LINE_PX = 684;
    localparam HB_W    = 86;    // pixels of Hblank per line
    localparam HS_ON   = 8;     // Hsync pulse position inside Hblank
    localparam HS_OFF  = 58;
    localparam LINES   = 262;
    localparam VB_L    = 20;    // lines of Vblank per field
    localparam FRAMES  = 4;

    reg clk = 0;
    always #11.64 clk = ~clk;

    // ---- stimulus: core-side video at ce_pix rate -------------------------
    reg        ce_pix = 0;
    reg  [1:0] ce_ph = 0;
    reg  [9:0] px = 0;
    reg  [8:0] ln = 0;
    reg  [2:0] frame = 0;
    reg        hs = 0, vs = 0, hb = 1, vb = 1;
    reg  [7:0] r = 0, g = 0, b = 0;
    reg        done = 0;

    always @(negedge clk) begin
        ce_ph  <= ce_ph + 1'd1;
        ce_pix <= ~ce_ph[1];           // 2 clks high, 2 low -> 10.74 MHz
        if (ce_ph == 2'd3) begin       // advance one pixel per ce period
            if (px == LINE_PX - 1) begin
                px <= 0;
                if (ln == LINES - 1) begin
                    ln <= 0;
                    frame <= frame + 1'd1;
                    if (frame == FRAMES - 1) done <= 1;
                end
                else ln <= ln + 1'd1;
            end
            else px <= px + 1'd1;
        end
    end

    wire [9:0] ax = px - HB_W;         // active pixel index
    always @(negedge clk) begin
        hb <= (px < HB_W);
        hs <= (px >= HS_ON) && (px < HS_OFF);
        vb <= (ln < VB_L);
        vs <= (ln >= 2) && (ln < 5);
        r  <= ax[7:0];
        g  <= {6'd0, ax[9:8]};
        b  <= ln[7:0];
    end

    // ---- Analogizer front end (openFPGA_Pocket_Analogizer.v "Fix video") --
    reg CE = 0, HS = 0, VS = 0, HBL = 1, VBL = 1, old_ce = 0;
    reg [7:0] R_fix = 0, G_fix = 0, B_fix = 0;
    wire DE = ~(HBL | VBL);
    always @(posedge clk) begin
        old_ce <= ce_pix;
        CE <= 0;
        if (~old_ce & ce_pix) begin
            CE <= 1;
            HS <= hs; VS <= vs; HBL <= hb; VBL <= vb;
            {R_fix, G_fix, B_fix} <= {r, g, b};
        end
    end

    wire       ce_o, hs_o, vs_o, hb_o, vb_o;
    wire [7:0] r_o, g_o, b_o;
    scandoubler_2 #(.LENGTH(LENGTH), .HALF_DEPTH(0)) dut (
        .clk_vid(clk), .hq2x(1'b0),
        .ce_pix(CE), .hs_in(HS), .vs_in(VS), .hb_in(HBL), .vb_in(VBL),
        .r_in(R_fix & {8{DE}}), .g_in(G_fix & {8{DE}}), .b_in(B_fix & {8{DE}}),
        .ce_pix_out(ce_o), .hs_out(hs_o), .vs_out(vs_o), .hb_out(hb_o), .vb_out(vb_o),
        .r_out(r_o), .g_out(g_o), .b_out(b_o)
    );

    // ---- checks on the doubled output -------------------------------------
    reg hs_d = 0, vs_d = 0, hb_d = 0, vb_d = 0;
    integer hs_pulses = 0, vs_pulses = 0, out_lines = 0, vb_lines = 0;
    integer samples = 0, px_errors = 0, line_id_errors = 0;
    integer line_min = 1 << 30, line_max = 0;
    integer cur_len = 0, prev_len = -1;
    reg [9:0] expect_x = 0;
    reg [7:0] cur_id = 0, prev_id = 8'hFF;
    integer id_repeat = 0;
    reg measuring = 0, started = 0, synced = 0;
    integer in_lines = 0;

    always @(posedge clk) begin
        hs_d <= hs_o; vs_d <= vs_o; hb_d <= hb_o; vb_d <= vb_o;
        if (frame == 2 && ln == 0 && px == 0) measuring <= 1;   // steady state
        if (!measuring) begin started <= 0; synced <= 0; end
        if (frame == FRAMES - 1 && ln == 0 && px == 0) measuring <= 0;

        if (measuring) begin
            if (~hs_d & hs_o) hs_pulses = hs_pulses + 1;
            if (~vs_d & vs_o) vs_pulses = vs_pulses + 1;

            // output line starts on the falling edge of hb_out; the line
            // in flight when measuring begins is partial and is skipped
            if (hb_d & ~hb_o) begin
                started <= 1;
                out_lines = out_lines + 1;
                if (vb_o) begin
                    vb_lines = vb_lines + 1;
                    prev_id = 8'hFF;       // pairs restart after vblank
                    id_repeat = 0;
                    synced <= 1;           // pair check armed from the first full field
                end
                expect_x = 0;
                cur_len = 0;
            end
            if (~hb_d & hb_o && ~vb_o && cur_len > 0 && started) begin
                if (cur_len < line_min) line_min = cur_len;
                if (cur_len > line_max) line_max = cur_len;
                // every input line must come out twice, back to back
                if (cur_id == prev_id) id_repeat = id_repeat + 1;
                else begin
                    if (id_repeat != 2 && prev_id != 8'hFF && synced) begin
                        line_id_errors = line_id_errors + 1;
                        $display("  line-pair error: id %0d emitted %0d times (next id %0d, output line %0d, input line %0d)",
                                 prev_id, id_repeat, cur_id, out_lines, ln);
                    end
                    id_repeat = 1;
                end
                prev_id = cur_id;
            end
            if (ce_o && ~hb_o && ~vb_o && started) begin
                samples = samples + 1;
                if (cur_len == 0) cur_id = b_o;
                if (r_o != expect_x[7:0] || g_o != {6'd0, expect_x[9:8]} || b_o != cur_id)
                    px_errors = px_errors + 1;
                expect_x = expect_x + 1'd1;
                cur_len = cur_len + 1;
            end
        end
    end

    always @(posedge clk) if (done) begin
        $display("LENGTH=%0d: measured %0d input frames (%0d lines each)",
                 LENGTH, FRAMES - 3, LINES);
        $display("  hs_out pulses   : %0d  (expect %0d = 2 per input line)", hs_pulses, 2 * LINES * (FRAMES - 3));
        $display("  vs_out pulses   : %0d  (expect %0d)", vs_pulses, FRAMES - 3);
        $display("  output lines    : %0d  (expect %0d), of which %0d in vblank (expect %0d)",
                 out_lines, 2 * LINES * (FRAMES - 3), vb_lines, 2 * VB_L * (FRAMES - 3));
        $display("  active px/line  : %0d..%0d  (expect %0d)", line_min, line_max, LINE_PX - HB_W);
        $display("  pixel mismatches: %0d of %0d samples", px_errors, samples);
        $display("  line-pair errors: %0d  (input lines not emitted exactly twice)", line_id_errors);
        if (hs_pulses == 2 * LINES * (FRAMES - 3) && vs_pulses == FRAMES - 3 &&
            out_lines == 2 * LINES * (FRAMES - 3) && px_errors == 0 &&
            line_id_errors == 0 && line_min == LINE_PX - HB_W && line_max == LINE_PX - HB_W)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
