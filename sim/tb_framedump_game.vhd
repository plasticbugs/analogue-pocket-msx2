-- Render one frame from REAL game state: VRAM, registers, and palette ripped
-- from openMSX running Bubble Bobble (C-BIOS MSX2) mid-gameplay. The dump is
-- compared row-by-row against openMSX's own rendering of the same state --
-- any divergence is a defect in our VDP, reproduced without hardware.
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.conv_std_logic_vector;
use std.textio.all;

entity tb_framedump_game is end tb_framedump_game;

architecture sim of tb_framedump_game is
    signal clk21m   : std_logic := '0';
    signal reset    : std_logic := '1';
    signal req      : std_logic := '0';
    signal ack      : std_logic;
    signal wrt      : std_logic := '0';
    signal adr      : std_logic_vector(15 downto 0) := (others => '0');
    signal dbi      : std_logic_vector(7 downto 0);
    signal dbo      : std_logic_vector(7 downto 0) := (others => '0');
    signal int_n    : std_logic;
    signal pramoe_n : std_logic;
    signal pramwe_n : std_logic;
    signal pramadr  : std_logic_vector(16 downto 0);
    signal pramdbi  : std_logic_vector(15 downto 0) := (others => '0');
    signal pramdbo  : std_logic_vector(7 downto 0);
    signal vr, vg, vb : std_logic_vector(5 downto 0);
    signal de, hs_n, vs_n, cs_n, dhclk, dlclk : std_logic;

    type ram_t is array (0 to 65535) of std_logic_vector(7 downto 0);

    impure function load_bank(fname : string) return ram_t is
        file f     : text open read_mode is fname;
        variable l : line;
        variable m : ram_t := (others => (others => '0'));
        variable c : character;
        variable hi, lo : integer;
        function hexval(c : character) return integer is
        begin
            case c is
                when '0' to '9' => return character'pos(c) - character'pos('0');
                when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
                when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
                when others     => return 0;
            end case;
        end function;
    begin
        for i in 0 to 65535 loop
            exit when endfile(f);
            readline(f, l);
            read(l, c); hi := hexval(c);
            read(l, c); lo := hexval(c);
            m(i) := conv_std_logic_vector(hi*16 + lo, 8);
        end loop;
        return m;
    end function;

    shared variable bank0 : ram_t := load_bank("vram_bank0.hex");
    shared variable bank1 : ram_t := load_bank("vram_bank1.hex");
    signal q0, q1 : std_logic_vector(7 downto 0) := (others => '0');

    type regs_t is array (0 to 27) of integer;
    -- from bb_regs.txt (openMSX, Bubble Bobble gameplay)
    constant REGS : regs_t := (
        6, 98, 31, 0, 0, 239, 31, 0, 40, 128, 0, 1, 0, 0, 3, 0,
        0, 47, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    type pal_t is array (0 to 15) of integer;
    -- from bb_pal.txt: word = RB byte + 256 * G byte
    constant PAL : pal_t := (
        0, 608, 1140, 1136, 1909, 1792, 115, 1911,
        71, 1366, 1093, 1798, 1031, 119, 1904, 1024);
begin
    clk21m <= not clk21m after 23.283 ns;
    reset  <= '1', '0' after 1 us;

    U_VDP: entity work.VDP
    port map (
        CLK21M => clk21m, RESET => reset,
        REQ => req, ACK => ack, WRT => wrt, ADR => adr, DBI => dbi, DBO => dbo,
        INT_N => int_n,
        PRAMOE_N => pramoe_n, PRAMWE_N => pramwe_n, PRAMADR => pramadr,
        PRAMDBI => pramdbi, PRAMDBO => pramdbo,
        VDPSPEEDMODE => '0', RATIOMODE => "000", CENTERYJK_R25_N => '1',
        PVIDEOR => vr, PVIDEOG => vg, PVIDEOB => vb, PVIDEODE => de,
        PVIDEOHS_N => hs_n, PVIDEOVS_N => vs_n, PVIDEOCS_N => cs_n,
        PVIDEODHCLK => dhclk, PVIDEODLCLK => dlclk,
        DISPRESO => '0',
        NTSC_PAL_TYPE => '0', FORCED_V_MODE => '0', LEGACY_VGA => '0'
    );

    vram: process(clk21m)
    begin
        if rising_edge(clk21m) then
            if pramwe_n = '0' then
                if pramadr(16) = '1' then
                    bank1(conv_integer(pramadr(15 downto 0))) := pramdbo;
                else
                    bank0(conv_integer(pramadr(15 downto 0))) := pramdbo;
                end if;
            end if;
            q0 <= bank0(conv_integer(pramadr(15 downto 0)));
            q1 <= bank1(conv_integer(pramadr(15 downto 0)));
        end if;
    end process;
    pramdbi <= q1 & q0;

    stim: process
        procedure pwr(port_lo : in integer; val : in integer) is
        begin
            wait until rising_edge(clk21m);
            adr <= conv_std_logic_vector(port_lo, 16);
            dbo <= conv_std_logic_vector(val, 8);
            wrt <= '1';
            req <= '1';
            wait until rising_edge(clk21m);
            req <= '0';
            wrt <= '0';
            for i in 0 to 40 loop
                wait until rising_edge(clk21m);
            end loop;
        end procedure;
        procedure vreg(r : in integer; val : in integer) is
        begin
            pwr(1, val);
            pwr(1, 128 + r);
        end procedure;
    begin
        wait until reset = '0';
        for i in 0 to 200 loop
            wait until rising_edge(clk21m);
        end loop;

        -- all registers except R1 (display enable last)
        for r in 0 to 27 loop
            if r /= 1 then
                vreg(r, REGS(r));
            end if;
        end loop;

        -- palette
        vreg(16, 0);
        for p in 0 to 15 loop
            pwr(2, PAL(p) mod 256);
            pwr(2, PAL(p) / 256);
        end loop;

        vreg(1, REGS(1));
        wait;
    end process;

    dump: process(clk21m)
        file f : text open write_mode is "frame_game.txt";
        variable l         : line;
        variable vs_prev   : std_logic := '1';
        variable de_prev   : std_logic := '0';
        variable vde_prev  : boolean := false;
        variable de_cnt    : integer := 0;
        variable de_line   : integer := 0;
        variable vde       : boolean;
        variable vs_count  : integer := 0;
        variable capturing : boolean := false;
        variable y         : integer := -1;
    begin
        if falling_edge(clk21m) and reset = '0' then
            if vs_prev = '1' and vs_n = '0' then
                de_line := 0;
            elsif de = '1' and de_prev = '0' then
                de_line := de_line + 1;
            end if;
            de_prev := de;

            vde := (de = '1') and (de_cnt = 4) and (de_line > 2);

            if vs_prev = '1' and vs_n = '0' then
                vs_count := vs_count + 1;
                if vs_count = 3 then
                    capturing := true;
                    y := -1;
                elsif vs_count = 4 then
                    write(l, string'("END"));
                    writeline(f, l);
                    report "DUMP COMPLETE: " & integer'image(y + 1) & " lines"
                        severity failure;
                end if;
            end if;

            if capturing then
                if vde and not vde_prev then
                    y := y + 1;
                    write(l, string'("LINE ") & integer'image(y));
                    writeline(f, l);
                end if;
                if vde then
                    write(l, integer'image(conv_integer(vr)) & " "
                           & integer'image(conv_integer(vg)) & " "
                           & integer'image(conv_integer(vb)));
                    writeline(f, l);
                end if;
            end if;

            if de = '0' then
                de_cnt := 0;
            elsif de_cnt /= 4 then
                de_cnt := de_cnt + 1;
            end if;
            vde_prev := vde;
            vs_prev  := vs_n;
        end if;
    end process;
end sim;
