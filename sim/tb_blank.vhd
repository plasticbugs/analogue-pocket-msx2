-- Measure the V9938's exported blanking (PVIDEO_HBLANK / PVIDEO_VBLANK)
-- against its sync pulses and display enable, for one full field.
--
-- These are the signals the Analogizer scandoubler times its output from,
-- so the bench checks what that consumer needs:
--   * Hblank pulses once per scan line -- including the vertical blanking
--     lines -- with the Hsync pulse falling entirely inside it
--   * Vblank covers a contiguous block of lines per field
--   * PVIDEODE == NOT (Hblank OR Vblank) on every clock
-- Run with sim/run_blank.sh; generic PAL selects the 313-line field.
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.conv_std_logic_vector;

entity tb_blank is
    generic (PAL : boolean := false);
end tb_blank;

architecture sim of tb_blank is
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
    signal win_y, hb, vbl : std_logic;

    function b2sl(b : boolean) return std_logic is
    begin
        if b then return '1'; else return '0'; end if;
    end function;
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
        NTSC_PAL_TYPE => '0', FORCED_V_MODE => b2sl(PAL), LEGACY_VGA => '0',
        PVIDEO_WINDOW_Y => win_y,
        PVIDEO_HBLANK => hb, PVIDEO_VBLANK => vbl
    );

    -- Enable the display so DE is live (blanking runs regardless).
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
        vreg(0, x"00");
        vreg(1, x"40");     -- display enable, no interrupts
        wait;
    end process;

    meas: process(clk21m)
        variable vs_prev, hb_prev, vbl_prev, hs_prev : std_logic := '1';
        variable vs_count   : integer := 0;
        variable capturing  : boolean := false;
        -- per field
        variable hb_falls   : integer := 0;   -- lines seen (hblank -> active video)
        variable hb_in_vbl  : integer := 0;   -- of which during vblank
        variable vbl_lines  : integer := 0;   -- lines with vblank asserted
        variable vbl_rises  : integer := 0;
        variable de_mismatch: integer := 0;
        variable hs_outside : integer := 0;   -- hsync edges seen while hblank low
        -- per line
        variable clk_in_line: integer := 0;
        variable hb_high    : integer := 0;
        variable hs_fall_at : integer := -1;
        variable hs_rise_at : integer := -1;
        variable line_len_min, line_len_max : integer := 0;
        variable hbw_min, hbw_max : integer := 0;
        variable hsf_min, hsf_max, hsr_min, hsr_max : integer := 0;
        variable first_line : boolean := true;
        variable have_stats : boolean := false;
    begin
        if rising_edge(clk21m) and reset = '0' then
            if vs_prev = '1' and vs_n = '0' then
                vs_count := vs_count + 1;
                if vs_count = 3 then
                    capturing := true;
                    hb_falls := 0; hb_in_vbl := 0; vbl_lines := 0; vbl_rises := 0;
                    de_mismatch := 0; hs_outside := 0; first_line := true; have_stats := false;
                elsif vs_count = 4 then
                    report "FIELD lines=" & integer'image(hb_falls)
                         & " hb_edges_during_vblank=" & integer'image(hb_in_vbl)
                         & " vblank_lines=" & integer'image(vbl_lines)
                         & " vblank_rises=" & integer'image(vbl_rises)
                         & " line_clocks=" & integer'image(line_len_min) & ".." & integer'image(line_len_max)
                         & " hblank_clocks=" & integer'image(hbw_min) & ".." & integer'image(hbw_max)
                         & " hsync_fall@=" & integer'image(hsf_min) & ".." & integer'image(hsf_max)
                         & " hsync_rise@=" & integer'image(hsr_min) & ".." & integer'image(hsr_max)
                         & " hsync_outside_hblank=" & integer'image(hs_outside)
                         & " de_mismatch=" & integer'image(de_mismatch)
                        severity failure;
                end if;
            end if;

            if capturing then
                if de /= (not (hb or vbl)) then
                    de_mismatch := de_mismatch + 1;
                end if;
                if hb = '1' then
                    hb_high := hb_high + 1;
                end if;
                -- hsync edges, measured in clocks since the start of hblank
                if hs_prev = '1' and hs_n = '0' then
                    hs_fall_at := clk_in_line;
                    if hb = '0' then hs_outside := hs_outside + 1; end if;
                end if;
                if hs_prev = '0' and hs_n = '1' then
                    hs_rise_at := clk_in_line;
                    if hb = '0' then hs_outside := hs_outside + 1; end if;
                end if;
                clk_in_line := clk_in_line + 1;

                if hb_prev = '0' and hb = '1' then
                    -- start of a new hblank: close the previous line
                    if not first_line then
                        if not have_stats then
                            have_stats := true;
                            line_len_min := clk_in_line; line_len_max := clk_in_line;
                            hbw_min := hb_high; hbw_max := hb_high;
                            hsf_min := hs_fall_at; hsf_max := hs_fall_at;
                            hsr_min := hs_rise_at; hsr_max := hs_rise_at;
                        else
                            if clk_in_line < line_len_min then line_len_min := clk_in_line; end if;
                            if clk_in_line > line_len_max then line_len_max := clk_in_line; end if;
                            if hb_high < hbw_min then hbw_min := hb_high; end if;
                            if hb_high > hbw_max then hbw_max := hb_high; end if;
                            if hs_fall_at < hsf_min then hsf_min := hs_fall_at; end if;
                            if hs_fall_at > hsf_max then hsf_max := hs_fall_at; end if;
                            if hs_rise_at < hsr_min then hsr_min := hs_rise_at; end if;
                            if hs_rise_at > hsr_max then hsr_max := hs_rise_at; end if;
                        end if;
                    end if;
                    first_line := false;
                    clk_in_line := 0;
                    hb_high := 1;
                    hs_fall_at := -1;
                    hs_rise_at := -1;
                end if;
                if hb_prev = '1' and hb = '0' then
                    hb_falls := hb_falls + 1;
                    if vbl = '1' then
                        hb_in_vbl := hb_in_vbl + 1;
                        vbl_lines := vbl_lines + 1;
                    end if;
                end if;
                if vbl_prev = '0' and vbl = '1' then
                    vbl_rises := vbl_rises + 1;
                end if;
            end if;

            vs_prev  := vs_n;
            hb_prev  := hb;
            vbl_prev := vbl;
            hs_prev  := hs_n;
        end if;
    end process;
end sim;
