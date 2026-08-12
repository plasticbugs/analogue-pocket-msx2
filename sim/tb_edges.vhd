library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

-- Samples the VDP output exactly the way the Pocket scaler does (every second
-- 21.477MHz cycle) and reports the pixels at the edges of the DE window, to
-- find out whether the first column / last row carry real border colour or a
-- transition artefact.
entity tb_edges is end tb_edges;

architecture sim of tb_edges is
    signal clk21m   : std_logic := '0';
    signal reset    : std_logic := '1';
    signal adr      : std_logic_vector(15 downto 0) := (others => '0');
    signal dbi      : std_logic_vector(7 downto 0);
    signal dbo      : std_logic_vector(7 downto 0) := (others => '0');
    signal pramadr  : std_logic_vector(16 downto 0);
    signal pramdbi  : std_logic_vector(15 downto 0) := (others => '0');
    signal pramdbo  : std_logic_vector(7 downto 0);
    signal pramoe_n, pramwe_n, ack, int_n : std_logic;
    signal vr, vg, vb : std_logic_vector(5 downto 0);
    signal de, hs_n, vs_n, cs_n, dhclk, dlclk : std_logic;
begin
    clk21m <= not clk21m after 23.283 ns;
    reset  <= '1', '0' after 1 us;

    U_VDP: entity work.VDP
    port map (
        CLK21M => clk21m, RESET => reset,
        REQ => '0', ACK => ack, WRT => '0', ADR => adr, DBI => dbi, DBO => dbo,
        INT_N => int_n,
        PRAMOE_N => pramoe_n, PRAMWE_N => pramwe_n, PRAMADR => pramadr,
        PRAMDBI => pramdbi, PRAMDBO => pramdbo,
        VDPSPEEDMODE => '0', RATIOMODE => "000", CENTERYJK_R25_N => '1',
        PVIDEOR => vr, PVIDEOG => vg, PVIDEOB => vb, PVIDEODE => de,
        PVIDEOHS_N => hs_n, PVIDEOVS_N => vs_n, PVIDEOCS_N => cs_n,
        PVIDEODHCLK => dhclk, PVIDEODLCLK => dlclk,
        DISPRESO => '0', NTSC_PAL_TYPE => '0', FORCED_V_MODE => '0',
        LEGACY_VGA => '0'
    );

    probe: process(clk21m)
        variable phase      : integer := 0;   -- 0/1 : which half of the pixel clock
        variable hs_prev    : std_logic := '1';
        variable vs_prev    : std_logic := '1';
        variable de_prev    : std_logic := '0';
        variable samples    : integer := 0;   -- clk_vid samples with DE this line
        variable line_no    : integer := 0;
        variable de_lines   : integer := 0;
        variable field      : integer := 0;
        variable first_px, second_px, last_px : string(1 to 6) := "      ";

        function rgbstr(r, g, b : std_logic_vector(5 downto 0)) return string is
            variable s : string(1 to 6);
            constant hexs : string(1 to 16) := "0123456789ABCDEF";
        begin
            s(1) := hexs(conv_integer(r(5 downto 2)) + 1);
            s(2) := hexs(conv_integer(r(1 downto 0)) + 1);
            s(3) := hexs(conv_integer(g(5 downto 2)) + 1);
            s(4) := hexs(conv_integer(g(1 downto 0)) + 1);
            s(5) := hexs(conv_integer(b(5 downto 2)) + 1);
            s(6) := hexs(conv_integer(b(1 downto 0)) + 1);
            return s;
        end function;
    begin
        if rising_edge(clk21m) and reset = '0' then
            -- emulate the scaler: one sample every second machine cycle
            if phase = 1 then
                if de = '1' then
                    samples := samples + 1;
                    if samples = 1 then first_px  := rgbstr(vr, vg, vb); end if;
                    if samples = 2 then second_px := rgbstr(vr, vg, vb); end if;
                    last_px := rgbstr(vr, vg, vb);
                end if;
            end if;
            phase := 1 - phase;

            if hs_prev = '1' and hs_n = '0' then
                if samples > 0 then
                    de_lines := de_lines + 1;
                    -- report the first display line, a middle one, and the last
                    if field = 3 and (de_lines = 1 or de_lines = 120 or de_lines = 242) then
                        report "line " & integer'image(de_lines)
                            & ": DE samples=" & integer'image(samples)
                            & " first=" & first_px & " second=" & second_px
                            & " last=" & last_px;
                    end if;
                end if;
                samples := 0;
                line_no := line_no + 1;
            end if;

            if vs_prev = '1' and vs_n = '0' then
                if field = 3 then
                    report "field had " & integer'image(de_lines) & " DE lines";
                    report "DONE" severity failure;
                end if;
                de_lines := 0;
                field := field + 1;
            end if;

            hs_prev := hs_n; vs_prev := vs_n; de_prev := de;
        end if;
    end process;
end sim;
