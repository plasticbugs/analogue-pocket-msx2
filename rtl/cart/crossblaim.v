//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// MSX Compatible Gateware IP Core
//
// Cross Blaim mapper (64kB, four 16kB banks). The whole address space is one
// switch region: any write latches the low two bits. Page 1 (4000-7fffh) is
// always bank 0. Page 2 (8000-bfffh) shows bank 1 for values 0/1, else the
// selected bank. Pages 0 and 3 mirror bank 1 for values 0/1 and are unmapped
// (FFh) otherwise. Semantics per openMSX RomCrossBlaim.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
//------------------------------------------------------------------------------

module cart_crossblaim
    (
        input            clk,
        input            reset,
        input     [15:0] addr,
        input      [7:0] d_from_cpu,
        input            wr,
        input            cs,
        output    [24:0] mem_addr,
        output           nomap
    );

    reg [1:0] mode;

    always @(posedge reset, posedge clk) begin
        if (reset) begin
            mode <= 2'd0;
        end
        else begin
            if (cs && wr) begin
                mode <= d_from_cpu[1:0];
            end
        end
    end

    wire       page1 = addr[15:14] == 2'b01;
    wire       page2 = addr[15:14] == 2'b10;
    wire [1:0] var_bank = mode[1] ? mode : 2'd1;

    wire [1:0] bank = page1 ? 2'd0 : var_bank;

    // pages 0 and 3 only mirror bank 1 while mode is 0/1
    assign nomap    = ~page1 & ~page2 & mode[1];
    assign mem_addr = {9'h0, bank, addr[13:0]};

endmodule
