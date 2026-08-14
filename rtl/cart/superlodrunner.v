//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// MSX Compatible Gateware IP Core
//
// Super Lode Runner mapper (16kB banks). The cartridge snoops the bus for
// writes to address 0000h regardless of slot selection (a "global write" in
// openMSX terms) and uses the value as the bank for page 2 (8000-bfffh).
// All other pages are unmapped. Semantics per openMSX RomSuperLodeRunner.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
//------------------------------------------------------------------------------

module cart_superlodrunner
    (
        input            clk,
        input            reset,
        input     [24:0] rom_size,
        input     [15:0] addr,
        input      [7:0] d_from_cpu,
        input            wr,
        output    [24:0] mem_addr,
        output           nomap
    );

    reg  [7:0] bank;
    wire [6:0] mask = rom_size[20:14] - 1'd1;

    // deliberately not qualified with cs: the real cartridge watches the bus
    always @(posedge reset, posedge clk) begin
        if (reset) begin
            bank <= 8'h00;
        end
        else begin
            if (wr && addr == 16'h0000) begin
                bank <= d_from_cpu;
            end
        end
    end

    wire page2 = addr[15:14] == 2'b10;

    assign nomap    = ~page2;
    assign mem_addr = {4'h0, (bank[6:0] & mask), addr[13:0]};

endmodule
