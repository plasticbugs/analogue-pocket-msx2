library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity tb_vdp is end tb_vdp;

architecture sim of tb_vdp is
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
    signal pal_mode : std_logic := '0';
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
        DISPRESO => '0',              -- 15kHz path (what the Pocket core uses)
        NTSC_PAL_TYPE => '0', FORCED_V_MODE => pal_mode, LEGACY_VGA => '0'
    );

    measure: process(clk21m)
        variable hs_prev, vs_prev, de_prev : std_logic := '1';
        variable clks_since_hs  : integer := 0;
        variable hs_count       : integer := 0;   -- hsync pulses since last vsync
        variable de_clks        : integer := 0;   -- DE-high clocks this line
        variable de_lines       : integer := 0;   -- lines with any DE this field
        variable field_count    : integer := 0;
        variable de_width_seen  : integer := 0;
    begin
        if rising_edge(clk21m) and reset = '0' then
            clks_since_hs := clks_since_hs + 1;
            if de = '1' then de_clks := de_clks + 1; end if;

            -- HSYNC falling edge = start of line
            if hs_prev = '1' and hs_n = '0' then
                if de_clks > 0 then
                    de_lines := de_lines + 1;
                    de_width_seen := de_clks;
                end if;
                if field_count = 3 and hs_count = 30 then
                    report "LINE: " & integer'image(clks_since_hs) & " clk21 per hsync"
                        & " | DE width " & integer'image(de_width_seen) & " clk21"
                        & " (= " & integer'image(de_width_seen/2) & " px at 10.74MHz)";
                end if;
                clks_since_hs := 0;
                de_clks := 0;
                hs_count := hs_count + 1;
            end if;

            -- VSYNC falling edge = start of field
            if vs_prev = '1' and vs_n = '0' then
                if field_count > 0 then
                    report "FIELD " & integer'image(field_count)
                        & ": hsync pulses = " & integer'image(hs_count)
                        & " | lines with DE = " & integer'image(de_lines);
                end if;
                hs_count := 0;
                de_lines := 0;
                field_count := field_count + 1;
                if field_count = 5 then
                    report "DONE" severity failure;
                end if;
            end if;

            hs_prev := hs_n;
            vs_prev := vs_n;
            de_prev := de;
        end if;
    end process;
end sim;
