//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// MSX Compatible Gateware IP Core
//
// Generic 8kB mapper (openMSX GENERIC_8KB, softwaredb alias "GenericKonami").
// Four switchable 8kB banks at 4000/6000/8000/A000h; a write anywhere inside
// a page sets that page's bank. This is also the correct fallback for
// MegaROMs with no recognizable bank-switch signatures, matching openMSX's
// guesser default.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
//------------------------------------------------------------------------------

module cart_generic8
    (
        input            clk,
        input            reset,
        input     [24:0] rom_size,
        input     [15:0] addr,
        input      [7:0] d_from_cpu,
        input            wr,
        input            cs,
        output    [24:0] mem_addr
    );

    reg  [7:0] bank0, bank1, bank2, bank3;
    // Round the mask up to the next power of two: dsk2rom conversions are
    // not power-of-two sized, and a subtractive mask has holes that corrupt
    // high bank numbers.
    wire [7:0] banks_m1 = rom_size[20:13] - 1'd1;
    wire [7:0] mask     = banks_m1 | (banks_m1 >> 1) | (banks_m1 >> 2) | (banks_m1 >> 4);

    always @(posedge reset, posedge clk) begin
        if (reset) begin
            bank0 <= 8'h00;
            bank1 <= 8'h01;
            bank2 <= 8'h02;
            bank3 <= 8'h03;
        end
        else begin
            if (cs && wr) begin
                case (addr[15:13])
                    3'b010: bank0 <= d_from_cpu; // 4000-5fffh
                    3'b011: bank1 <= d_from_cpu; // 6000-7fffh
                    3'b100: bank2 <= d_from_cpu; // 8000-9fffh
                    3'b101: bank3 <= d_from_cpu; // a000-bfffh
                endcase
            end
        end
    end

    wire [7:0] bank_base = addr[15:13] == 3'b010 ? bank0 :
                           addr[15:13] == 3'b011 ? bank1 :
                           addr[15:13] == 3'b100 ? bank2 : bank3;

    assign mem_addr = {4'h0, (bank_base & mask), addr[12:0]};

endmodule
