-- Frame dump in Bubble Bobble's exact video configuration: GRAPHIC4
-- (SCREEN 5) bitmap, 212-line mode, sprites enabled 16x16, R18 h-adjust -4.
-- Register values taken from openMSX running the real cartridge.
--
-- Every bitmap line y is filled with colour 1+(y mod 14), and the palette
-- programmed so each colour index is a unique RGB triple. The dump therefore
-- identifies, per DE window line, WHICH display line landed there -- any
-- dropped, shifted or duplicated lines at the top or bottom of the frame are
-- visible directly.
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.conv_std_logic_vector;
use std.textio.all;

entity tb_framedump5 is end tb_framedump5;

architecture sim of tb_framedump5 is
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

    -- SCREEN 5 page 0: bitmap at 0x0000, 128 bytes/line, 212 lines.
    -- Sprite attribute table (R11=1, R5=239): 0xF780.
    impure function init_bank0 return ram_t is
        variable m : ram_t := (others => (others => '0'));
        variable c : integer;
    begin
        for y in 0 to 211 loop
            c := 1 + (y mod 14);
            for x in 0 to 127 loop
                m(y*128 + x) := conv_std_logic_vector(c*16 + c, 8);
            end loop;
        end loop;
        -- sprite attribute table: y=216 terminates sprite display (mode 2)
        m(16#F780#) := conv_std_logic_vector(216, 8);
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

    -- CPU-side register setup: Bubble Bobble's values, minus interrupt enable
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
        variable rb, gg : integer;
    begin
        wait until reset = '0';
        for i in 0 to 200 loop
            wait until rising_edge(clk21m);
        end loop;

        vreg(0, x"06");     -- M4+M3: GRAPHIC4 (SCREEN 5)
        vreg(2, x"1F");     -- bitmap page 0
        vreg(5, x"EF");     -- sprite attr low
        vreg(11, x"01");    -- sprite attr high -> 0xF780
        vreg(6, x"1F");     -- sprite pattern
        vreg(7, x"00");     -- border colour 0
        vreg(8, x"28");     -- sprites on, per real game
        vreg(9, x"80");     -- 212-line mode, NTSC
        vreg(10, x"00");
        vreg(14, x"00");
        vreg(18, x"0C");    -- h-adjust -4, v-adjust 0 (as the game sets)
        vreg(23, x"00");    -- no vertical scroll

        -- palette: entry i -> unique triple (i&7, (i/2)&7, (15-i)&7)
        vreg(16, x"00");
        for i in 0 to 15 loop
            rb := (i mod 8)*16 + ((15-i) mod 8);
            gg := (i/2) mod 8;
            pwr(2, conv_std_logic_vector(rb, 8));
            pwr(2, conv_std_logic_vector(gg, 8));
        end loop;

        vreg(1, x"42");     -- display on, 16x16 sprites, no interrupts
        wait;
    end process;

    -- frame capture on CLK21M falling edges (= hardware clk_vid sample points)
    dump: process(clk21m)
        file f : text open write_mode is "frame5.txt";
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
            -- vertical trim: drop the first 2 window lines (NTSC), as in
            -- rtl/msx2.sv (v_trim)
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
