//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2026, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// MSX Compatible Gateware IP Core
//
// Mapper database autodetect engine.
//
// The cartridge download stream is hashed with SHA-1 on the fly; when a
// slot finishes loading, the digest's first 8 bytes are looked up in
// mapperdb.bin (distilled from openMSX's softwaredb by
// tools/make_mapperdb.py and downloaded into its own SDRAM region). A hit
// overrides the instruction-counting heuristic in rom_detect; the user's
// manual menu pick still overrides everything. The machine is held in
// reset while a scan runs (worst case ~13ms for 3000 entries at 21MHz).
//
// The parent owns the SDRAM mux: while `scanning` is high it must route
// `db_addr`/`db_rd` to the SDRAM controller and return dout/ready here;
// while the database file streams in (ioctl_isMAPDB) it must write the
// bytes to the same region base.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
//------------------------------------------------------------------------------

module mapper_db
    (
        input             clk,
        // download stream
        input             ioctl_wr,
        input      [24:0] ioctl_addr,
        input       [7:0] ioctl_dout,
        input             ioctl_isROMA,
        input             ioctl_isROMB,
        input             ioctl_isMAPDB,
        input             hold,         // parent owns the SDRAM port: wait
        output            stall,        // hash engine busy: hold the bridge
        // SDRAM read port (valid while scanning)
        output            scanning,
        output reg [24:0] db_addr,
        output reg        db_rd,
        input       [7:0] sdram_dout,
        input             sdram_ready,
        // results
        output reg  [3:0] db_mapper_A,
        output reg        db_valid_A = 0,
        output reg  [3:0] db_mapper_B,
        output reg        db_valid_B = 0,
        output            db_loaded_o,
        output            db_pending
    );

    reg ioctl_wr_d, rom_stream_d, sha1_done_d, mapdb_d;

    wire rom_stream  = ioctl_isROMA | ioctl_isROMB;
    wire stream_byte = rom_stream & ioctl_wr & ~ioctl_wr_d;
    wire mapdb_byte  = ioctl_isMAPDB & ioctl_wr & ~ioctl_wr_d;

    wire         sha1_done;
    wire [159:0] sha1_digest;

    sha1_stream sha1
    (
        .clk      ( clk                         ),
        .start    ( rom_stream & ~rom_stream_d  ),
        .byte_en  ( stream_byte                 ),
        .byte_in  ( ioctl_dout                  ),
        .finalize ( rom_stream_d & ~rom_stream  ),
        .busy     ( stall                       ),
        .done     ( sha1_done                   ),
        .digest   ( sha1_digest                 )
    );

    // database header, captured as the file streams in
    reg        db_loaded   = 0;
    reg  [3:0] db_magic_ok = 0;
    reg [31:0] db_count    = 0;

    always @(posedge clk) begin
        ioctl_wr_d   <= ioctl_wr;
        rom_stream_d <= rom_stream;
        sha1_done_d  <= sha1_done;
        mapdb_d      <= ioctl_isMAPDB;

        if (mapdb_byte) begin
            case (ioctl_addr)
                25'd0: db_magic_ok[0] <= ioctl_dout == "M";
                25'd1: db_magic_ok[1] <= ioctl_dout == "D";
                25'd2: db_magic_ok[2] <= ioctl_dout == "B";
                25'd3: db_magic_ok[3] <= ioctl_dout == "1";
                25'd4: db_count[7:0]   <= ioctl_dout;
                25'd5: db_count[15:8]  <= ioctl_dout;
                25'd6: db_count[23:16] <= ioctl_dout;
                25'd7: db_count[31:24] <= ioctl_dout;
                default: ;
            endcase
        end
        if (mapdb_d & ~ioctl_isMAPDB) begin
            db_loaded <= &db_magic_ok && db_count != 0;
        end
    end

    // per-slot digests waiting to be looked up
    reg  [63:0] db_key_A, db_key_B;
    reg   [1:0] db_pend     = 0;

    assign db_loaded_o = db_loaded;
    assign db_pending  = db_loaded & (db_pend != 0);
    reg         hash_slot;                // 0 = A, 1 = B

    // lookup engine
    reg         db_scanning = 0;
    reg         db_slot;
    reg  [31:0] db_entry;
    reg   [3:0] db_byte;                  // 0-7 key, 8 mapper
    reg  [63:0] db_key_sr;
    reg   [2:0] db_state;
    reg   [3:0] db_settle;

    assign scanning = db_scanning;

    wire [63:0] db_target = db_slot ? db_key_B : db_key_A;

    always @(posedge clk) begin
        db_rd <= 0;

        if (rom_stream & ~rom_stream_d) begin
            hash_slot <= ioctl_isROMB;
            if (ioctl_isROMB) begin db_valid_B <= 0; db_pend[1] <= 0; end
            else              begin db_valid_A <= 0; db_pend[0] <= 0; end
        end

        if (sha1_done & ~sha1_done_d) begin
            if (hash_slot) begin db_key_B <= sha1_digest[159:96]; db_pend[1] <= 1; end
            else           begin db_key_A <= sha1_digest[159:96]; db_pend[0] <= 1; end
        end

        if (!db_scanning) begin
            if (db_loaded && db_pend != 0 && !rom_stream && !ioctl_isMAPDB && !hold) begin
                db_slot     <= db_pend[0] ? 1'b0 : 1'b1;
                db_scanning <= 1;
                db_entry    <= 0;
                db_addr     <= 25'd8;
                db_byte     <= 0;
                db_state    <= 0;
            end
        end
        else begin
            case (db_state)
                3'd0: begin db_rd <= 1; db_state <= 3'd1; db_settle <= 0; end
                3'd1: begin
                    // let the registered ready fall, then wait for data
                    db_settle <= db_settle + 1'd1;
                    if (db_settle == 4'd5) db_state <= 3'd2;
                end
                3'd2: if (sdram_ready) begin
                    db_addr <= db_addr + 1'd1;
                    if (db_byte != 4'd8) begin
                        db_key_sr <= {db_key_sr[55:0], sdram_dout};
                        db_byte   <= db_byte + 1'd1;
                        db_state  <= 3'd0;
                    end
                    else begin
                        // ninth byte: the mapper id; keys are sorted, so
                        // passing the target means it is not in the table
                        db_byte <= 0;
                        if (db_key_sr == db_target) begin
                            if (db_slot) begin db_mapper_B <= sdram_dout[3:0]; db_valid_B <= 1; end
                            else         begin db_mapper_A <= sdram_dout[3:0]; db_valid_A <= 1; end
                            db_scanning <= 0;
                            db_pend[db_slot] <= 0;
                        end
                        else if (db_key_sr > db_target || db_entry == db_count - 1'd1) begin
                            db_scanning <= 0;
                            db_pend[db_slot] <= 0;
                        end
                        else begin
                            db_entry <= db_entry + 1'd1;
                            db_state <= 3'd0;
                        end
                    end
                end
                default: db_state <= 3'd0;
            endcase
        end
    end

endmodule
