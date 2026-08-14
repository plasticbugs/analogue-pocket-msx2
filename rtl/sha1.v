//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// MSX Compatible Gateware IP Core
//
// Streaming SHA-1 (FIPS 180-4). Bytes are fed one at a time as they arrive
// from the download bridge; each filled 64-byte block runs the 80-round
// compression at one round per clock, during which busy is high and the
// feeder must hold off (wired into ioctl_wait upstream). After the last
// byte, a finalize pulse makes the module generate the 0x80/zero padding
// and the 64-bit big-endian bit length internally.
//
// The digest keys the mapper-database lookup: the table stores the first
// 8 bytes of each known dump's SHA-1 (openMSX softwaredb numbers).
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
//------------------------------------------------------------------------------

module sha1_stream
    (
        input              clk,
        input              start,     // pulse: begin a new message
        input              byte_en,   // pulse: byte_in is the next byte
        input        [7:0] byte_in,
        input              finalize,  // pulse after the last message byte
        output             busy,      // compressing: do not feed bytes
        output reg         done,      // digest is valid
        output reg [159:0] digest
    );

    localparam H0 = 32'h67452301, H1 = 32'hEFCDAB89, H2 = 32'h98BADCFE,
               H3 = 32'h10325476, H4 = 32'hC3D2E1F0;

    reg [31:0] h0, h1, h2, h3, h4;
    reg [31:0] a, b, c, d, e;
    reg [31:0] w [0:15];
    reg  [6:0] t;            // round counter
    reg  [5:0] blk_pos;      // byte position within the current block
    reg [31:0] msg_bytes;    // total message length in bytes
    reg  [2:0] state;
    reg  [3:0] len_pos;      // which length byte is being emitted

    localparam S_ACCUM = 3'd0,  // accepting message bytes
               S_COMP  = 3'd1,  // 80 rounds + state update
               S_PAD   = 3'd2,  // emitting 0x80 / zero padding
               S_LEN   = 3'd3,  // emitting the 8 length bytes
               S_DONE  = 3'd4;

    // return-to state after a compression finishes
    reg  [2:0] resume;

    assign busy = (state == S_COMP);

    // 16-word ring buffer: for round t, W[t-16] lives at t mod 16, so the
    // taps at t-14/t-8/t-3 sit at +2/+8/+13 (mod 16) from there
    wire  [3:0] ti  = t[3:0];
    wire  [3:0] i2  = ti + 4'd2;
    wire  [3:0] i8  = ti + 4'd8;
    wire  [3:0] i13 = ti + 4'd13;
    wire [31:0] w16 = w[i13] ^ w[i8] ^ w[i2] ^ w[ti];
    wire [31:0] wt  = t < 16 ? w[ti] : {w16[30:0], w16[31]};

    wire [31:0] f = t < 20 ? (b & c) | (~b & d)           :
                    t < 40 ? b ^ c ^ d                    :
                    t < 60 ? (b & c) | (b & d) | (c & d)  :
                             b ^ c ^ d                    ;

    wire [31:0] k = t < 20 ? 32'h5A827999 :
                    t < 40 ? 32'h6ED9EBA1 :
                    t < 60 ? 32'h8F1BBCDC :
                             32'hCA62C1D6 ;

    wire [31:0] tval = {a[26:0], a[31:27]} + f + e + k + wt;

    // 64-bit big-endian bit length; message fits in 32 bits of bytes
    wire [63:0] bitlen = {29'd0, msg_bytes, 3'd0};
    wire  [7:0] len_byte = len_pos == 0 ? bitlen[63:56] :
                           len_pos == 1 ? bitlen[55:48] :
                           len_pos == 2 ? bitlen[47:40] :
                           len_pos == 3 ? bitlen[39:32] :
                           len_pos == 4 ? bitlen[31:24] :
                           len_pos == 5 ? bitlen[23:16] :
                           len_pos == 6 ? bitlen[15:8]  :
                                          bitlen[7:0]   ;

    // one write port into the block buffer, shared by message bytes,
    // padding and length bytes
    reg        pad_first;
    reg        put;
    reg  [7:0] put_byte;

    always @(*) begin
        put      = 1'b0;
        put_byte = 8'h00;
        case (state)
            S_ACCUM: begin put = byte_en; put_byte = byte_in; end
            S_PAD:   begin put = 1'b1;   put_byte = pad_first ? 8'h80 : 8'h00; end
            S_LEN:   begin put = 1'b1;   put_byte = len_byte; end
            default: ;
        endcase
    end

    // finalize can arrive while the last full block is still compressing
    // (every ROM is a multiple of 64 bytes), so it must be latched
    reg fin_pend = 0;

    integer i;
    always @(posedge clk) begin
        if (finalize) fin_pend <= 1'b1;
        if (start) begin
            h0 <= H0; h1 <= H1; h2 <= H2; h3 <= H3; h4 <= H4;
            blk_pos   <= 0;
            msg_bytes <= 0;
            state     <= S_ACCUM;
            done      <= 0;
            fin_pend  <= finalize;
        end
        else begin
            case (state)
                S_ACCUM, S_PAD, S_LEN: begin
                    if (state == S_ACCUM && fin_pend) begin
                        state     <= S_PAD;
                        pad_first <= 1'b1;
                        fin_pend  <= 1'b0;
                    end
                    else if (put) begin
                        // big-endian byte lanes within each 32-bit word
                        case (blk_pos[1:0])
                            2'd0: w[blk_pos[5:2]][31:24] <= put_byte;
                            2'd1: w[blk_pos[5:2]][23:16] <= put_byte;
                            2'd2: w[blk_pos[5:2]][15:8]  <= put_byte;
                            2'd3: w[blk_pos[5:2]][7:0]   <= put_byte;
                        endcase
                        blk_pos <= blk_pos + 1'd1;
                        if (state == S_ACCUM) msg_bytes <= msg_bytes + 1'd1;
                        if (state == S_PAD) begin
                            pad_first <= 1'b0;
                            // stop padding when the next free byte is 56
                            if (blk_pos == 6'd55) begin
                                state   <= S_LEN;
                                len_pos <= 0;
                            end
                        end
                        if (state == S_LEN) begin
                            len_pos <= len_pos + 1'd1;
                        end
                        if (blk_pos == 6'd63) begin
                            // block full: compress, then come back
                            a <= h0; b <= h1; c <= h2; d <= h3; e <= h4;
                            t      <= 0;
                            resume <= state == S_ACCUM ? S_ACCUM :
                                      state == S_LEN && len_pos == 4'd7 ? S_DONE :
                                      state == S_LEN ? S_LEN : S_PAD;
                            state  <= S_COMP;
                        end
                    end
                end

                S_COMP: begin
                    a <= tval;
                    b <= a;
                    c <= {b[1:0], b[31:2]};
                    d <= c;
                    e <= d;
                    w[t[3:0]] <= wt;
                    t <= t + 1'd1;
                    if (t == 7'd79) begin
                        h0 <= h0 + tval;
                        h1 <= h1 + a;
                        h2 <= h2 + {b[1:0], b[31:2]};
                        h3 <= h3 + c;
                        h4 <= h4 + d;
                        state <= resume;
                        if (resume == S_DONE) begin
                            digest <= {h0 + tval, h1 + a,
                                       h2 + {b[1:0], b[31:2]},
                                       h3 + c, h4 + d};
                            done   <= 1'b1;
                        end
                    end
                end

                S_DONE: ;
                default: state <= S_DONE;
            endcase
        end
    end

endmodule
