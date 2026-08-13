-- Dump one full field of DE-qualified video to a text file, so the exact
-- pixel stream the Pocket scaler receives can be inspected offline.
--
-- Setup: SCREEN 1 (GRAPHIC1), every character a solid 8x8 block, white on
-- black, blue border. The frame dump then shows -- unambiguously -- on which
-- DE window line the picture content starts and ends, whether all 192
-- display lines are present, and whether the first/last window lines carry
-- stale colours. This discriminates a core-side rendering fault from a
-- Pocket-scaler-side capture offset.
--
-- The DE trim from rtl/msx2.sv (DE_TRIM=4) is replicated here, and pixels
-- are sampled on the falling edge of CLK21M -- the same half-period offset
-- the phase-shifted clk_vid uses on hardware. Samples are logged at full
-- machine-clock rate (1192 per line); the analyser downsamples.
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.conv_std_logic_vector;
use std.textio.all;

entity tb_framedump is end tb_framedump;

architecture sim of tb_framedump is
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

    -- SCREEN 1 layout: pattern 0x0000, name 0x1800, colour 0x2000,
    -- sprite attributes 0x1B00.
    impure function init_bank0 return ram_t is
        variable m : ram_t := (others => (others => '0'));
    begin
        -- pattern generator: every character solid
        for i in 0 to 2047 loop
            m(i) := x"FF";
        end loop;
        -- name table: row r filled with character r (rows 0..23)
        for r in 0 to 23 loop
            for c in 0 to 31 loop
                m(16#1800# + r*32 + c) := conv_std_logic_vector(r, 8);
            end loop;
        end loop;
        -- colour table: white on black for all characters
        for i in 0 to 31 loop
            m(16#2000# + i) := x"F1";
        end loop;
        -- sprite attribute table: y=208 terminator, no sprites
        m(16#1B00#) := x"D0";
        return m;
    end function;

    shared variable bank0 : ram_t := init_bank0;
    shared variable bank1 : ram_t := (others => (others => '0'));
    signal q0, q1 : std_logic_vector(7 downto 0) := (others => '0');
begin
    clk21m <= not clk21m after 23.283 ns;   -- 21.47727 MHz
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

    -- two-bank VRAM, 1-clock latency, same wiring as rtl/msx2.sv
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

    checkmem: process
    begin
        wait for 10 ns;
        report "bank0[0x2000]=" & integer'image(conv_integer(bank0(8192)))
             & " bank0[0x1800]=" & integer'image(conv_integer(bank0(6144)))
             & " bank0[7]=" & integer'image(conv_integer(bank0(7)));
        wait;
    end process;

    -- CPU-side register setup
    stim: process
        procedure pwr(port_lo : in integer; val : in std_logic_vector(7 downto 0)) is
        begin
            wait until rising_edge(clk21m);
            adr <= conv_std_logic_vector(port_lo, 16);
            dbo <= val;
            wrt <= '1';
            req <= '1';
            wait until rising_edge(clk21m);
            req <= '0';
            wrt <= '0';
            for i in 0 to 40 loop
                wait until rising_edge(clk21m);
            end loop;
        end procedure;
        procedure vreg(r : in integer; val : in std_logic_vector(7 downto 0)) is
        begin
            pwr(1, val);
            pwr(1, conv_std_logic_vector(128 + r, 8));
        end procedure;
    begin
        wait until reset = '0';
        for i in 0 to 200 loop
            wait until rising_edge(clk21m);
        end loop;

        vreg(0, x"00");     -- GRAPHIC1
        vreg(2, x"06");     -- name table    0x1800
        vreg(3, x"80");     -- colour table  0x2000
        vreg(4, x"00");     -- pattern table 0x0000
        vreg(5, x"36");     -- sprite attr   0x1B00
        vreg(6, x"07");     -- sprite pattern 0x3800
        vreg(7, x"04");     -- border colour 4
        vreg(10, x"00");    -- colour table high bits (never reset in RTL)
        vreg(11, x"00");    -- sprite attr high bits (never reset in RTL)
        vreg(14, x"00");    -- VRAM access high bits

        -- palette: 1 = black, 4 = blue, 15 = white
        vreg(16, x"01");
        pwr(2, x"00");  pwr(2, x"00");
        vreg(16, x"04");
        pwr(2, x"07");  pwr(2, x"00");
        vreg(16, x"0F");
        pwr(2, x"77");  pwr(2, x"07");

        vreg(1, x"40");     -- display enable, no interrupts
        wait;
    end process;

    -- frame capture on CLK21M falling edges (= hardware clk_vid sample points)
    dump: process(clk21m)
        file f : text open write_mode is "frame.txt";
        variable l         : line;
        variable vs_prev   : std_logic := '1';
        variable vde_prev  : boolean := false;
        variable de_cnt    : integer := 0;
        variable vde       : boolean;
        variable vs_count  : integer := 0;
        variable capturing : boolean := false;
        variable y         : integer := -1;
    begin
        if falling_edge(clk21m) and reset = '0' then
            vde := (de = '1') and (de_cnt = 4);

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
