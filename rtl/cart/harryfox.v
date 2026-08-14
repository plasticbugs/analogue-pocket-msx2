//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// MSX Compatible Gateware IP Core
//
// Harry Fox - Yuki no Maou Hen mapper (64kB, four 16kB banks). Writes to
// 6000-6fffh pick page 1's bank from the even banks (0/2) via bit 0; writes
// to 7000-7fffh pick page 2's bank from the odd banks (1/3). Pages 0 and 3
// are unmapped. Semantics per openMSX RomHarryFox.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
//------------------------------------------------------------------------------

module cart_harryfox
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

    reg sel1, sel2;

    always @(posedge reset, posedge clk) begin
        if (reset) begin
            sel1 <= 1'b0;
            sel2 <= 1'b0;
        end
        else begin
            if (cs && wr) begin
                if (addr[15:12] == 4'h6) sel1 <= d_from_cpu[0]; // 6000-6fffh
                if (addr[15:12] == 4'h7) sel2 <= d_from_cpu[0]; // 7000-7fffh
            end
        end
    end

    wire       page1 = addr[15:14] == 2'b01;
    wire       page2 = addr[15:14] == 2'b10;
    wire [1:0] bank  = page1 ? {sel1, 1'b0} : {sel2, 1'b1};

    assign nomap    = ~page1 & ~page2;
    assign mem_addr = {9'h0, bank, addr[13:0]};

endmodule
