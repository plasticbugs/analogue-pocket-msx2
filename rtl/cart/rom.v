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
// Notes: https://www.msx.org/wiki/ROM_mappers
//------------------------------------------------------------------------------

module cart_rom
    (
        input  wire        clk,
        input  wire        clk_en,
        input  wire        reset,
        input  wire [15:0] addr,
        input  wire        wr,
        input  wire        rd,
        input  wire        CS1_n,
        input  wire        CS2_n,
        input  wire        CS12_n,
        input  wire      SLTSL_n,
        input  wire  [7:0] d_from_cpu,
        output wire  [7:0] d_to_cpu,
        output wire [14:0] sound,

        input  wire        ioctl_wr,
        input  wire [24:0] ioctl_addr,
        input  wire  [7:0] ioctl_dout,
        input  wire        ioctl_isROM,
        output wire        ioctl_wait,
        input  wire  [3:0] user_mapper,
        output wire  [3:0] detected_mapper,
        output wire  [3:0] active_mapper,
        output wire  [7:0] stream_sum,
        output wire [24:0] rom_size_o,
        input  wire  [7:0] ram_dout,
        output wire  [7:0] ram_din,
        output wire [24:0] ram_addr,
        output wire        ram_we,
        output wire        ram_rd,
        input  wire        ram_ready,
        input  wire        rom_enabled
    );

    assign ram_din = ioctl_dout;
    assign ram_rd = ~SLTSL_n & ~ioctl_isROM;
    assign ram_we = rom_we;
    assign detected_mapper = auto_mapper;
    assign active_mapper   = mapper;

    assign d_to_cpu = mapper == 4  && scc_ack             ? d_to_cpu_scc   :
                      mapper == 2  && sram_oe_gamemaster2 ? d_to_cpu_sram  :
                      mapper == 6  && sram_oe_ascii16     ? d_to_cpu_sram  :
                      mapper == 5  && sram_oe_ascii8      ? d_to_cpu_sram  :
                      mapper == 11 && nomap_crossblaim    ? 8'hFF          :
                      mapper == 12 && nomap_harryfox      ? 8'hFF          :
                      mapper == 13 && nomap_slodrunner    ? 8'hFF          :
                      ~rom_enabled                        ? 8'hFF          :
                                                            ram_dout       ;

    assign sound = mapper == 4 ? scc_sound : 14'h0;

    wire rom_we = ioctl_isROM & ioctl_wr;

    wire [7:0] d_to_cpu_sram;
    wire [12:0] sram_addr;
    wire sram_we;
    spram #(.addr_width(13),.mem_name("CART_SRAM")) cart_sram
    (
        .clock   ( clk           ),
        .address ( sram_addr     ),
        .wren    ( sram_we       ),
        .q       ( d_to_cpu_sram ),
        .data    ( d_from_cpu    )
    );

    assign ioctl_wait = ~ram_ready && ioctl_isROM;

    wire [3:0] mapper;

    // 0  uknown
    // 1  nomaper
    // 2  gamemaster2
    // 3  konami
    // 4  konami SCC
    // 5  ASCII 8
    // 6  ASCII 16
    // 7  linear (nomaper) 64kb. Aligned ROM image is replicated to 64KB area.
    // 8  R-TYPE
    // 9  FDD VY0010
    // 10 generic 8k (openMSX GENERIC_8KB / "GenericKonami")
    // 11 Cross Blaim
    // 12 Harry Fox
    // 13 Super Lode Runner

    assign mapper   = user_mapper == 0 ? auto_mapper : user_mapper;
    assign ram_addr = ioctl_isROM  ? ioctl_addr            :
                      mapper == 2  ? mem_addr_gamemaster2  :
                      mapper == 3  ? mem_addr_konami       :
                      mapper == 4  ? mem_addr_konami_scc   :
                      mapper == 5  ? mem_addr_ascii8       :
                      mapper == 6  ? mem_addr_ascii16      :
                      mapper == 8  ? mem_addr_ascii16      :
                      mapper == 10 ? mem_addr_generic8     :
                      mapper == 11 ? mem_addr_crossblaim   :
                      mapper == 12 ? mem_addr_harryfox     :
                      mapper == 13 ? mem_addr_slodrunner   :
                      mapper == 7  ? addr & (rom_size - 1) :
                                     addr - {offset,12'd0} ; // default nomaper

    assign sram_addr = mapper == 2 ? sram_addr_gamemaster2 :
                       mapper == 6 ? sram_addr_ascii16     :
                       mapper == 5 ? sram_addr_ascii8      :
                       'h0;

    assign sram_we   = mapper == 2 ? sram_we_gamemaster2 :
                       mapper == 6 ? sram_we_ascii16     :
                       mapper == 5 ? sram_we_ascii8      :
                       'h0;

    wire [3:0]  offset;
    wire [24:0] rom_size;
    wire [3:0]  auto_mapper;

    assign rom_size_o = rom_size;

    rom_detect rom_detect
    (
        .clk         ( clk         ),
        .ioctl_isROM ( ioctl_isROM ),
        .ioctl_addr  ( ioctl_addr  ),
        .ioctl_dout  ( ioctl_dout  ),
        .rom_we      ( rom_we      ),
        .mapper      ( auto_mapper ),
        .offset      ( offset      ),
        .rom_size    ( rom_size    ),
        .stream_sum  ( stream_sum  )
    );

    wire [24:0] mem_addr_konami;

    cart_konami konami
    (
        .clk        ( clk             ),
        .reset      ( reset           ),
        .rom_size   ( rom_size        ),
        .addr       ( addr            ),
        .d_from_cpu ( d_from_cpu      ),
        .wr         ( wr              ),
        .cs         ( ~SLTSL_n        ),
        .mem_addr   ( mem_addr_konami )
    );

    wire [24:0] mem_addr_konami_scc;
    wire [7:0]  d_to_cpu_scc;
    wire        scc_ack;
    wire [14:0] scc_sound;

    cart_konami_scc konami_scc
    (
        .clk        ( clk                 ),
        .clk_en     ( clk_en              ),
        .reset      ( reset               ),
        .rom_size   ( rom_size            ),
        .addr       ( addr                ),
        .d_from_cpu ( d_from_cpu          ),
        .d_to_cpu   ( d_to_cpu_scc        ),
        .ack        ( scc_ack             ),
        .wr         ( wr                  ),
        .rd         ( rd                  ),
        .cs         ( ~SLTSL_n            ),
        .mem_addr   ( mem_addr_konami_scc ),
        .scc_sound  ( scc_sound           )
    );

    wire [24:0] mem_addr_ascii8;
    wire [12:0] sram_addr_ascii8;
    wire        sram_we_ascii8;
    wire        sram_oe_ascii8;

    cart_asci8 ascii8
    (
        .clk        ( clk              ),
        .reset      ( reset            ),
        .rom_size   ( rom_size         ),
        .addr       ( addr             ),
        .d_from_cpu ( d_from_cpu       ),
        .wr         ( wr               ),
        .cs         ( ~SLTSL_n         ),
        .mem_addr   ( mem_addr_ascii8  ),
        .sram_addr  ( sram_addr_ascii8 ),
        .sram_we    ( sram_we_ascii8   ),
        .sram_oe    ( sram_oe_ascii8   )
    );

    wire [24:0] mem_addr_ascii16;
    wire [12:0] sram_addr_ascii16;
    wire        sram_we_ascii16;
    wire        sram_oe_ascii16;

    cart_asci16 ascii16
    (
        .clk        ( clk               ),
        .reset      ( reset             ),
        .rom_size   ( rom_size          ),
        .addr       ( addr              ),
        .d_from_cpu ( d_from_cpu        ),
        .wr         ( wr                ),
        .cs         ( ~SLTSL_n          ),
        .mem_addr   ( mem_addr_ascii16  ),
        .r_type     ( mapper == 8       ),
        .sram_addr  ( sram_addr_ascii16 ),
        .sram_we    ( sram_we_ascii16   ),
        .sram_oe    ( sram_oe_ascii16   )
    );

    wire [24:0] mem_addr_generic8;

    cart_generic8 generic8
    (
        .clk        ( clk               ),
        .reset      ( reset             ),
        .rom_size   ( rom_size          ),
        .addr       ( addr              ),
        .d_from_cpu ( d_from_cpu        ),
        .wr         ( wr                ),
        .cs         ( ~SLTSL_n          ),
        .mem_addr   ( mem_addr_generic8 )
    );

    wire [24:0] mem_addr_crossblaim;
    wire        nomap_crossblaim;

    cart_crossblaim crossblaim
    (
        .clk        ( clk                 ),
        .reset      ( reset               ),
        .addr       ( addr                ),
        .d_from_cpu ( d_from_cpu          ),
        .wr         ( wr                  ),
        .cs         ( ~SLTSL_n            ),
        .mem_addr   ( mem_addr_crossblaim ),
        .nomap      ( nomap_crossblaim    )
    );

    wire [24:0] mem_addr_harryfox;
    wire        nomap_harryfox;

    cart_harryfox harryfox
    (
        .clk        ( clk               ),
        .reset      ( reset             ),
        .addr       ( addr              ),
        .d_from_cpu ( d_from_cpu        ),
        .wr         ( wr                ),
        .cs         ( ~SLTSL_n          ),
        .mem_addr   ( mem_addr_harryfox ),
        .nomap      ( nomap_harryfox    )
    );

    wire [24:0] mem_addr_slodrunner;
    wire        nomap_slodrunner;

    cart_superlodrunner slodrunner
    (
        .clk        ( clk                 ),
        .reset      ( reset               ),
        .rom_size   ( rom_size            ),
        .addr       ( addr                ),
        .d_from_cpu ( d_from_cpu          ),
        .wr         ( wr                  ),
        .mem_addr   ( mem_addr_slodrunner ),
        .nomap      ( nomap_slodrunner    )
    );

    wire [24:0] mem_addr_gamemaster2;
    wire [12:0] sram_addr_gamemaster2;
    wire        sram_we_gamemaster2;
    wire        sram_oe_gamemaster2;

    cart_gamemaster2 gamemaster2
    (
        .clk        ( clk                   ),
        .reset      ( reset                 ),
        .addr       ( addr                  ),
        .d_from_cpu ( d_from_cpu            ),
        .wr         ( wr                    ),
        .cs         ( ~SLTSL_n              ),
        .mem_addr   ( mem_addr_gamemaster2  ),
        .sram_addr  ( sram_addr_gamemaster2 ),
        .sram_we    ( sram_we_gamemaster2   ),
        .sram_oe    ( sram_oe_gamemaster2   )
    );

endmodule
