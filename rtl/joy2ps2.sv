//------------------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2024, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// Joystick to PS/2 Keyboard
//
// Copyright (c) 2024, Marcus Andrade <marcus@opengateware.org>
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

`default_nettype none
`timescale 1ns/1ps

module joy2ps2
    (
        input   wire        clk,
        input   wire        reset,     // Reset signal
        input   wire        enable,    // Reset signal
        input   wire [35:0] key_map,   // six 6-bit key indices:
                                       // [5:0] Y, [11:6] X, [17:12] L, [23:18] R,
                                       // [29:24] Select, [35:30] Start
        input   wire  [9:0] joy_key,   // [9] Up, [8] Down, [7] Left, [6] Right,
                                       // [5] Start, [4] Select, [3] R1, [2] L1, [1] X, [0] Y
        output logic [10:0] ps2_key    // [10] Strobe, [9] Pressed/Released, [8:0] Scancode
    );

    // Define states for the state machine
    typedef enum logic [2:0] {
                KEY_IDLE,
                KEY_SAVE,
                KEY_PRESSED,
                KEY_HELD,
                KEY_RELEASED_TO_IDLE,
                KEY_RELEASED_TO_NEW
            } KeyState;

    KeyState state, next_state;

    // PS/2 Keyboard Internal Logic
    reg       key_strobe;
    reg       key_pressed;
    reg [8:0] key_code;

    // PS/2 Translation
    reg [8:0] ps2_scancode, ps2_scancode_last;
    reg [8:0] key_code_saved;
    reg       save_key;

    parameter SC_UP       = 9'h175, // Arrow Up
              SC_DOWN     = 9'h172, // Arrow Down
              SC_LEFT     = 9'h16B, // Arrow Left
              SC_RIGHT    = 9'h174; // Arrow Right

    // Full keyboard table, indexed by the mapping sliders. The numbering is
    // designed to be memorable without a manual: 0 none, 1-26 = A-Z,
    // 27-36 = digits 0-9, then specials (documented in info.txt).
    function [8:0] key_sc(input [5:0] i);
        case (i)
            6'd1 : key_sc = 9'h01C;  6'd2 : key_sc = 9'h032; // A B
            6'd3 : key_sc = 9'h021;  6'd4 : key_sc = 9'h023; // C D
            6'd5 : key_sc = 9'h024;  6'd6 : key_sc = 9'h02B; // E F
            6'd7 : key_sc = 9'h034;  6'd8 : key_sc = 9'h033; // G H
            6'd9 : key_sc = 9'h043;  6'd10: key_sc = 9'h03B; // I J
            6'd11: key_sc = 9'h042;  6'd12: key_sc = 9'h04B; // K L
            6'd13: key_sc = 9'h03A;  6'd14: key_sc = 9'h031; // M N
            6'd15: key_sc = 9'h044;  6'd16: key_sc = 9'h04D; // O P
            6'd17: key_sc = 9'h015;  6'd18: key_sc = 9'h02D; // Q R
            6'd19: key_sc = 9'h01B;  6'd20: key_sc = 9'h02C; // S T
            6'd21: key_sc = 9'h03C;  6'd22: key_sc = 9'h02A; // U V
            6'd23: key_sc = 9'h01D;  6'd24: key_sc = 9'h022; // W X
            6'd25: key_sc = 9'h035;  6'd26: key_sc = 9'h01A; // Y Z
            6'd27: key_sc = 9'h045;  6'd28: key_sc = 9'h016; // 0 1
            6'd29: key_sc = 9'h01E;  6'd30: key_sc = 9'h026; // 2 3
            6'd31: key_sc = 9'h025;  6'd32: key_sc = 9'h02E; // 4 5
            6'd33: key_sc = 9'h036;  6'd34: key_sc = 9'h03D; // 6 7
            6'd35: key_sc = 9'h03E;  6'd36: key_sc = 9'h046; // 8 9
            6'd37: key_sc = 9'h029;                          // SPACE
            6'd38: key_sc = 9'h05A;                          // RETURN
            6'd39: key_sc = 9'h012;                          // SHIFT
            6'd40: key_sc = 9'h014;                          // CTRL
            6'd41: key_sc = 9'h111;                          // GRAPH
            6'd42: key_sc = 9'h009;                          // CODE
            6'd43: key_sc = 9'h076;                          // ESC
            6'd44: key_sc = 9'h00D;                          // TAB
            6'd45: key_sc = 9'h066;                          // BACKSPACE
            6'd46: key_sc = SC_UP;
            6'd47: key_sc = SC_DOWN;
            6'd48: key_sc = SC_LEFT;
            6'd49: key_sc = SC_RIGHT;
            6'd50: key_sc = 9'h005;  6'd51: key_sc = 9'h006; // F1 F2
            6'd52: key_sc = 9'h004;  6'd53: key_sc = 9'h00C; // F3 F4
            6'd54: key_sc = 9'h003;                          // F5
            6'd55: key_sc = 9'h078;                          // SELECT (F11)
            6'd56: key_sc = 9'h17C;                          // STOP
            6'd57: key_sc = 9'h16C;                          // HOME
            6'd58: key_sc = 9'h170;                          // INS
            6'd59: key_sc = 9'h171;                          // DEL
            default: key_sc = 9'h000;                        // none
        endcase
    endfunction

    wire [8:0] MAP_Y  = key_sc(key_map[5:0]);
    wire [8:0] MAP_X  = key_sc(key_map[11:6]);
    wire [8:0] MAP_L  = key_sc(key_map[17:12]);
    wire [8:0] MAP_R  = key_sc(key_map[23:18]);
    wire [8:0] MAP_SE = key_sc(key_map[29:24]);
    wire [8:0] MAP_ST = key_sc(key_map[35:30]);

    always_ff @(posedge clk) begin : joy2scancode
        if (reset) begin
            ps2_scancode <= 9'h0;
        end
        else begin
            if(joy_key != 10'h0) begin
                case(joy_key)
                    10'h001: begin ps2_scancode <= MAP_Y;    end // [0] Y
                    10'h002: begin ps2_scancode <= MAP_X;    end // [1] X
                    10'h004: begin ps2_scancode <= MAP_L;    end // [2] L
                    10'h008: begin ps2_scancode <= MAP_R;    end // [3] R
                    10'h010: begin ps2_scancode <= MAP_SE;   end // [4] Select
                    10'h020: begin ps2_scancode <= MAP_ST;   end // [5] Start
                    // d-pad always doubles as the cursor keys: keyboard-only
                    // loaders (SD Snatcher's, Disk BASIC menus) ignore the
                    // joystick port entirely
                    10'h040: begin ps2_scancode <= SC_RIGHT; end // [6] Right
                    10'h080: begin ps2_scancode <= SC_LEFT;  end // [7] Left
                    10'h100: begin ps2_scancode <= SC_DOWN;  end // [8] Down
                    10'h200: begin ps2_scancode <= SC_UP;    end // [9] Up
                    default: begin /* DO NOTHING */          end
                endcase
            end
            else begin
                ps2_scancode <= 9'h0;
            end
        end
    end

    // Save Scancode
    always_ff @(posedge clk) begin : saveScancode
        key_code_saved <= (save_key) ? ps2_scancode : key_code_saved;
    end

    // State Machine Controller
    always_ff @(posedge clk) begin : scancodeFSM
        if (reset) begin
            state <= KEY_IDLE;
        end
        else begin
            ps2_scancode_last <= ps2_scancode;
            state             <= next_state;
        end
    end

    // PS/2 Translation
    always_comb begin : scancodeTranslation
        next_state  = state;
        key_code    = 9'h000;
        key_pressed = 1'b0;
        key_strobe  = 1'b0;
        save_key    = 1'b0;

        case (state)
            KEY_IDLE: begin
                key_code = 9'h000;
                // Detect zero to non-zero transition
                if(~|ps2_scancode_last & |ps2_scancode) begin
                    next_state = KEY_SAVE;
                end
            end
            KEY_SAVE: begin
                save_key   = 1'b1;
                next_state = KEY_PRESSED;
            end
            KEY_PRESSED: begin
                key_code    = key_code_saved;
                key_pressed = 1'b1;
                key_strobe  = 1'b1;
                next_state  = KEY_HELD;
            end
            KEY_HELD: begin
                key_code    = key_code_saved;
                key_pressed = 1'b1;
                key_strobe  = 1'b0;
                // Detect non-zero to zero transition
                if(|ps2_scancode_last & ~|ps2_scancode) begin
                    next_state = KEY_RELEASED_TO_IDLE;
                end
                else if (ps2_scancode_last != ps2_scancode) begin
                    next_state = KEY_RELEASED_TO_NEW;
                end
            end
            KEY_RELEASED_TO_IDLE: begin
                key_code    = key_code_saved;
                key_pressed = 1'b0;
                key_strobe  = 1'b1;
                next_state  = KEY_IDLE;
            end
            KEY_RELEASED_TO_NEW: begin
                key_code    = key_code_saved;
                key_strobe  = 1'b1;
                key_pressed = 1'b0;
                next_state  = KEY_SAVE;
            end
            default: begin
                next_state  = KEY_IDLE;
            end
        endcase
    end

    // PS/2 Keyboard Output
    assign ps2_key = enable ? {key_strobe, key_pressed, key_code} : 11'h0;

endmodule
