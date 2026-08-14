//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2024, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// MSX Compatible Gateware IP Core
//
// Copyright (c) 2022, Molekula <@tdlabac>
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

module rom_detect
    (
        input             clk,
        input             ioctl_isROM,
        input      [24:0] ioctl_addr,
        input       [7:0] ioctl_dout,
        input             rom_we,
        output      [2:0] mapper,
        output      [3:0] offset,
        output reg [24:0] rom_size,
        output reg  [7:0] stream_sum
    );

    reg               last_isROM;
    reg         [7:0] head[0:7];
    reg         [7:0] head2[0:7];
    reg signed [15:0] asc16, asc8, kon4, kon5;
    reg               game1, game2;

    always @(posedge clk) begin
        last_isROM <= ioctl_isROM;
    end

    // ioctl_wr is held high for several clocks per byte (DIO_HOLD), so acting
    // on the level feeds every ROM byte into the detector that many times. The
    // mapper signatures are three-byte sequences -- LD (6000h),A and friends --
    // which can never appear in a stream where each byte repeats, so nothing
    // was ever detected and every MegaROM fell through to the ASCII16 default.
    // Take one sample per byte.
    reg  last_rom_we;
    wire rom_we_edge = rom_we & ~last_rom_we;

    always @(posedge clk) begin
        last_rom_we <= rom_we;
    end

    always @(posedge clk) begin
        reg [7:0] a0,a1,a2;

        if (ioctl_isROM && ~last_isROM) begin
            stream_sum <= 0;
            asc16 <= 0;
            asc8  <= 0;
            kon4  <= 0;
            kon5  <= 0;
            game1 <= 0;
            game2 <= 0;
            a0    <= 0;
            a1    <= 0;
            a2    <= 0;
        end
        if (rom_we_edge) begin
            rom_size <= ioctl_addr + 1'd1 ;
            stream_sum <= stream_sum + ioctl_dout;
            if (ioctl_addr[24:7] == 0) begin
                if (ioctl_addr[5:3] == 0) begin
                    if (ioctl_addr[6] == 0) begin
                        head  [ioctl_addr[2:0]] <= ioctl_dout;
                        head2 [ioctl_addr[2:0]] <= 0;
                    end
                    else begin
                        head2[ioctl_addr[2:0]] <= ioctl_dout;
                    end
                end
                if (ioctl_addr[6:1] == 6'b001000) begin
                    if (ioctl_addr[0] == 0 && ioctl_dout == "Y") game1 <= 1;
                    if (ioctl_addr[0] == 1 && ioctl_dout == "Z") game2 <= 1;
                end
            end
            a0 <= a1;
            a1 <= a2;
            a2 <= ioctl_dout;
            // Count LD (nnnn),A instructions targeting mapper bank registers.
            // Match the register WINDOW (high byte range), not one exact
            // address: games hit any address inside a window -- Bubble Bobble
            // writes its ASCII8 banks at 77F8h/7FF8h, which an exact-address
            // match (or a low-byte-zero filter) never sees.
            //   ASCII8     : 6000-7FFF in four 800h windows
            //   ASCII16    : 6000-67FF, 7000-77FF
            //   Konami     : 6000-67FF, 8000-87FF, A000-A7FF
            //   Konami SCC : 5000-57FF, 7000-77FF, 9000-97FF, B000-B7FF
            if (ioctl_addr > 2)	begin
                if (a0 == 8'h32) begin
                    case (a2[7:3])
                        5'b01010:            begin kon5 <= kon5 + 1'd1; end                                                          // 50xx-57xx
                        5'b01100:            begin asc8 <= asc8 + 1'd1; asc16 <= asc16 + 1'd1; kon4 <= kon4 + 1'd1; end              // 60xx-67xx
                        5'b01101:            begin asc8 <= asc8 + 1'd1; end                                                          // 68xx-6Fxx
                        5'b01110:            begin asc8 <= asc8 + 1'd1; asc16 <= asc16 + 1'd1; kon5 <= kon5 + 1'd1; end              // 70xx-77xx
                        5'b01111:            begin asc8 <= asc8 + 1'd1; end                                                          // 78xx-7Fxx
                        5'b10000, 5'b10100:  begin kon4 <= kon4 + 1'd1; end                                                          // 80xx-87xx, A0xx-A7xx
                        5'b10010, 5'b10110:  begin kon5 <= kon5 + 1'd1; end                                                          // 90xx-97xx, B0xx-B7xx
                        default: ;
                    endcase
                end
            end
        end
    end

    // 0 uknown
    // 1 nomaper
    // 2 gamemaster2
    // 3 konami
    // 4 konami SCC
    // 5 ASCII 8
    // 6 ASCII 16

    wire [15:0] kon    = kon4 > kon5  ? kon4 : kon5;
    wire [15:0] ascii  = asc8 > asc16 ? asc8 : asc16;

    // With no bank-switch signatures at all, default to ASCII8 -- the same
    // choice as openMSX's guesser (GENERIC_8KB).
    assign      mapper = rom_size                   < 25'h2000  ? 3'd0 :
                         rom_size                   < 25'h10000 ? 3'd1 :
                         rom_size && game1 && game2 > 25'h18000 ? 3'd2 :
                         kon > ascii                            ? (kon5 > kon4  ? 3'd4 : 3'd3) :
                         (ascii == 0)                           ? 3'd5 :
                                                                  (asc8 > asc16 ? 3'd5 : 3'd6) ;

    wire [15:0] start          = head[3]  << 8 | head[2];
    wire [15:0] start4000      = head2[3] << 8 | head2[2];
    wire        romSig_at_0000 = head [0] == "A" && head [1] == "B";
    wire        romSig_at_4000 = head2[0] == "A" && head2[1] == "B";

    wire [3:0] start_1 = start == 0 ? ((head[5] & 8'hC0) != 8'h40 ? 4'h8 : 4'h4) : ((start & 16'hC000) == 16'h8000 ? 4'h8 : 4'h4);
    wire [3:0] start_2 = ( ~romSig_at_0000 &&  romSig_at_4000 ) ? ((start4000 == 0 && (head2[5] & 8'hC0) == 8'h40) || start4000 < 16'h8000 || start4000 >= 16'hC000) ? 4'h0 : 4'h4 : 4'h4;
    wire [3:0] start_3 = (~(romSig_at_0000 && ~romSig_at_4000)) ? 4'h0 : 4'h4;

    assign offset = rom_size == 16'h1000 ? start_1 :
                    rom_size == 16'h2000 ? start_1 :
                    rom_size == 16'h4000 ? start_1 :
                    rom_size == 16'h8000 ? start_2 :
                    rom_size == 16'hC000 ? start_3 : 4'h0;

endmodule
