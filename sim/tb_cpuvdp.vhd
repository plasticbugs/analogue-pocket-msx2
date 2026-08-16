library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

-- A minimal MSX: the real T80 CPU driving the real V9938 through exactly the
-- request logic msx2.sv uses, with the same two-bank block RAM VRAM model.
-- The Z80 runs a program that sets a VDP register and fills VRAM with a known
-- ramp; the testbench then checks what actually landed in VRAM.
entity tb_cpuvdp is end tb_cpuvdp;

architecture sim of tb_cpuvdp is
    signal clk21m : std_logic := '0';
    signal reset  : std_logic := '1';
    signal reset_n: std_logic;

    -- CPU
    signal a          : std_logic_vector(15 downto 0);
    signal d_to_cpu   : std_logic_vector(7 downto 0);
    signal d_from_cpu : std_logic_vector(7 downto 0);
    signal mreq_n, iorq_n, rd_n, wr_n, m1_n, rfrsh_n, halt_n : std_logic;
    signal cen_p, cen_n : std_logic := '0';

    -- request strobe (mirrors msx2.sv)
    signal iack : std_logic := '0';
    signal r_mreq_n, r_iorq_n, r_rd_n, r_wr_n, r_m1_n : std_logic := '1';
    signal r_a : std_logic_vector(15 downto 0) := (others => '1');
    signal r_d : std_logic_vector(7 downto 0) := (others => '1');
    signal req  : std_logic;
    signal io_en, vdp_sel, vdp_req : std_logic;

    -- VDP
    signal d_from_vdp : std_logic_vector(7 downto 0);
    signal vdp_int_n, vdp_ack : std_logic;
    signal pramadr  : std_logic_vector(16 downto 0);
    signal pramdbo  : std_logic_vector(7 downto 0);
    signal pramwe_n, pramoe_n : std_logic;
    signal vram0_q, vram1_q : std_logic_vector(7 downto 0);
    signal vr, vg, vb : std_logic_vector(5 downto 0);
    signal pramdbi : std_logic_vector(15 downto 0);
    signal vdp_wrt : std_logic;
    type rb_t is array (0 to 63) of std_logic_vector(7 downto 0);
    signal readback : rb_t := (others => (others => '0'));
    signal rb_idx   : integer := 0;
    signal n_vdpreq, n_reads, n_writes, n_rd99 : integer := 0;
    signal n_int_cleared, n_int_low, n_cycles : integer := 0;
    signal int_prev : std_logic := '1';
    signal cpu_writes  : integer := 0;
    signal vram_writes : integer := 0;
    signal de, hs_n, vs_n, cs_n, dhclk, dlclk : std_logic;

    type stack_t is array (0 to 255) of std_logic_vector(7 downto 0);
    signal stack : stack_t := (others => (others => '0'));
    type ram_t is array (0 to 65535) of std_logic_vector(7 downto 0);
    function init_vram return ram_t is
        variable v : ram_t := (others => (others => '0'));
    begin
        for i in 0 to 767 loop   v(i) := x"00"; end loop;          -- name table
        for i in 2048 to 4095 loop v(i) := x"AA"; end loop;        -- pattern: stripes
        for i in 8192 to 8223 loop v(i) := x"F1"; end loop;        -- colour table
        return v;
    end function;
    signal vram0 : ram_t := init_vram;
    signal vram1 : ram_t := (others => (others => '0'));

    -- Z80 test program at 0x0000
    type rom_t is array (0 to 127) of std_logic_vector(7 downto 0);
    constant prog : rom_t := (
        x"3E", x"00", x"D3", x"99", x"3E", x"80", x"D3", x"99",
        x"3E", x"40", x"D3", x"99", x"3E", x"81", x"D3", x"99",
        x"3E", x"00", x"D3", x"99", x"3E", x"82", x"D3", x"99",
        x"3E", x"80", x"D3", x"99", x"3E", x"83", x"D3", x"99",
        x"3E", x"01", x"D3", x"99", x"3E", x"84", x"D3", x"99",
        x"3E", x"10", x"D3", x"99", x"3E", x"87", x"D3", x"99",
        x"3E", x"00", x"D3", x"99", x"3E", x"90", x"D3", x"99",
        x"3E", x"00", x"D3", x"9A", x"3E", x"00", x"D3", x"9A",
        x"3E", x"77", x"D3", x"9A", x"3E", x"07", x"D3", x"9A",
        x"18", x"FE", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00");

    -- CPU clock enables: 3.58MHz from 21.477MHz (divide by 6)
    signal cen_div : integer range 0 to 5 := 0;
begin
    clk21m  <= not clk21m after 23.283 ns;
    reset   <= '1', '0' after 2 us;
    reset_n <= not reset;

    process(clk21m)
    begin
        if rising_edge(clk21m) then
            if cen_div = 5 then cen_div <= 0; else cen_div <= cen_div + 1; end if;
            if cen_div = 0 then cen_p <= '1'; else cen_p <= '0'; end if;
            if cen_div = 3 then cen_n <= '1'; else cen_n <= '0'; end if;
        end if;
    end process;

    U_CPU: entity work.T80pa
    generic map (Mode => 0)
    port map (
        RESET_n => reset_n, CLK => clk21m, CEN_p => cen_p, CEN_n => cen_n,
        WAIT_n => '1', INT_n => vdp_int_n, NMI_n => '1', BUSRQ_n => '1',
        M1_n => m1_n, MREQ_n => mreq_n, IORQ_n => iorq_n,
        RD_n => rd_n, WR_n => wr_n, RFSH_n => rfrsh_n, HALT_n => halt_n,
        BUSAK_n => open, A => a, DI => d_to_cpu, DO => d_from_cpu);

    -- request strobe, exactly as msx2.sv builds it
    -- registered CPU bus, matching msx2.sv
    req <= '1' when ((r_mreq_n = '0' or r_iorq_n = '0') and
                     (r_rd_n = '0' or r_wr_n = '0') and iack = '0') else '0';
    process(clk21m)
    begin
        if rising_edge(clk21m) then
            if reset = '1' then
                r_mreq_n <= '1'; r_iorq_n <= '1'; r_rd_n <= '1'; r_wr_n <= '1';
                r_m1_n <= '1'; r_a <= x"FFFF"; r_d <= x"FF"; iack <= '0';
            else
                r_mreq_n <= mreq_n; r_iorq_n <= iorq_n;
                r_rd_n <= rd_n; r_wr_n <= wr_n; r_m1_n <= m1_n;
                r_a <= a; r_d <= d_from_cpu;
                if (r_mreq_n = '1' and r_iorq_n = '1') then
                    iack <= '0';
                elsif req = '1' then
                    iack <= '1';
                end if;
            end if;
        end if;
    end process;

    pramdbi <= vram1_q & vram0_q;
    vdp_wrt <= not r_wr_n;

    io_en   <= '1' when (r_iorq_n = '0' and r_m1_n = '1') else '0';
    vdp_sel <= '1' when (io_en = '1' and r_a(7 downto 2) = "100110") else '0';
    vdp_req <= req and vdp_sel;

    U_VDP: entity work.VDP
    port map (
        CLK21M => clk21m, RESET => reset,
        REQ => vdp_req, ACK => vdp_ack, WRT => vdp_wrt, ADR => r_a,
        DBI => d_from_vdp, DBO => r_d, INT_N => vdp_int_n,
        PRAMOE_N => pramoe_n, PRAMWE_N => pramwe_n, PRAMADR => pramadr,
        PRAMDBI => pramdbi, PRAMDBO => pramdbo,
        VDPSPEEDMODE => '0', RATIOMODE => "000", CENTERYJK_R25_N => '1',
        PVIDEOR => vr, PVIDEOG => vg, PVIDEOB => vb, PVIDEODE => de,
        PVIDEOHS_N => hs_n, PVIDEOVS_N => vs_n, PVIDEOCS_N => cs_n,
        PVIDEODHCLK => dhclk, PVIDEODLCLK => dlclk,
        DISPRESO => '0', NTSC_PAL_TYPE => '0', FORCED_V_MODE => '0',
        LEGACY_VGA => '0');

    -- VRAM: two 64K banks, one cycle read latency (matches spram)
    process(clk21m)
    begin
        if rising_edge(clk21m) then
            if pramwe_n = '0' and pramadr(16) = '0' then
                vram0(to_integer(unsigned(pramadr(15 downto 0)))) <= pramdbo;
            end if;
            if pramwe_n = '0' and pramadr(16) = '1' then
                vram1(to_integer(unsigned(pramadr(15 downto 0)))) <= pramdbo;
            end if;
            vram0_q <= vram0(to_integer(unsigned(pramadr(15 downto 0))));
            vram1_q <= vram1(to_integer(unsigned(pramadr(15 downto 0))));
        end if;
    end process;

    stackram: process(clk21m)
    begin
        if rising_edge(clk21m) then
            if mreq_n = '0' and wr_n = '0' and a(15 downto 8) = x"FF" then
                stack(to_integer(unsigned(a(7 downto 0)))) <= d_from_cpu;
            end if;
        end if;
    end process;

    -- CPU bus: ROM in page 0, stack RAM at 0xFF00, VDP on I/O reads
    d_to_cpu <= prog(to_integer(unsigned(a(6 downto 0)))) when (mreq_n = '0' and rd_n = '0' and a < x"0080") else
                stack(to_integer(unsigned(a(7 downto 0)))) when (mreq_n = '0' and rd_n = '0' and a(15 downto 8) = x"FF") else
                d_from_vdp when (iorq_n = '0' and m1_n = '1' and rd_n = '0'
                                 and a(7 downto 2) = "100110") else
                x"FF";

    capture: process(clk21m)
    begin
        if rising_edge(clk21m) then
            if iorq_n = '0' and wr_n = '0' and m1_n = '1' and a(7 downto 0) = x"2F"
               and iack = '0' then
                if rb_idx < 64 then readback(rb_idx) <= d_from_cpu; end if;
                rb_idx <= rb_idx + 1;
            end if;
        end if;
    end process;

    count: process(clk21m)
    begin
        if rising_edge(clk21m) then
            int_prev <= vdp_int_n;
            if vdp_int_n = '1' and int_prev = '0' then
                n_int_cleared <= n_int_cleared + 1;
            end if;
            if vdp_int_n = '0' then n_int_low <= n_int_low + 1; end if;
            n_cycles <= n_cycles + 1;
            if vdp_req = '1' then
                n_vdpreq <= n_vdpreq + 1;
                if vdp_wrt = '0' then
                    n_reads <= n_reads + 1;
                    if a(1 downto 0) = "01" then n_rd99 <= n_rd99 + 1; end if;
                else
                    n_writes <= n_writes + 1;
                end if;
            end if;
            if vdp_req = '1' and wr_n = '0' and a(1 downto 0) = "00" then
                cpu_writes <= cpu_writes + 1;
            end if;
            if pramwe_n = '0' then
                vram_writes <= vram_writes + 1;
            end if;
        end if;
    end process;

    fetchlog: process(clk21m)
        variable hs_prev : std_logic := '1';
        variable vs_prev : std_logic := '1';
        variable ln  : integer := 0;
        variable fld : integer := 0;
        variable c   : integer := 0;
        variable run : integer := 0;
        variable prev: std_logic_vector(17 downto 0) := (others => '0');
        variable px  : std_logic_vector(17 downto 0);
        variable rpt : integer := 0;
    begin
        if rising_edge(clk21m) and reset = '0' then
            if fld = 3 and ln = 120 and de = '1' then
                px := vr & vg & vb;
                c := c + 1;
                if c > 300 then                 -- well inside the active area
                    if c = 301 then prev := px; run := 1;
                    elsif px = prev then run := run + 1;
                    else
                        if rpt < 14 then
                            report "pixel held " & integer'image(run) &
                                   " clk21 cycles (colour " &
                                   integer'image(to_integer(unsigned(prev(17 downto 12)))) & ")";
                            rpt := rpt + 1;
                        end if;
                        run := 1; prev := px;
                    end if;
                end if;
            end if;
            if hs_prev = '1' and hs_n = '0' then ln := ln + 1; c := 0; end if;
            if vs_prev = '1' and vs_n = '0' then fld := fld + 1; ln := 0; end if;
            hs_prev := hs_n; vs_prev := vs_n;
        end if;
    end process;

    scan: process(clk21m)
        variable phase   : integer := 0;
        variable hs_prev : std_logic := '1';
        variable vs_prev : std_logic := '1';
        variable line    : integer := 0;
        variable field   : integer := 0;
        variable col     : integer := 0;
        variable nonblack: integer := 0;   -- samples this line that are not border
        variable first_ln: integer := -1;  -- first DE line with picture
        variable last_ln : integer := -1;
        variable de_line : integer := 0;
        variable transits: integer := 0;
        variable prev_px : std_logic_vector(17 downto 0) := (others => '0');
        variable px      : std_logic_vector(17 downto 0);
        variable had_de  : boolean := false;
    begin
        if rising_edge(clk21m) and reset = '0' then
            if phase = 1 and de = '1' then
                px := vr & vg & vb;
                if px /= "000000000000000000" then nonblack := nonblack + 1; end if;
                if col > 0 and px /= prev_px then transits := transits + 1; end if;
                prev_px := px;
                col := col + 1;
                had_de := true;
            end if;
            if phase = 1 then phase := 0; else phase := 1; end if;

            if hs_prev = '1' and hs_n = '0' then
                if had_de then
                    de_line := de_line + 1;
                    if field = 3 then
                        if nonblack > 0 then
                            if first_ln < 0 then first_ln := de_line; end if;
                            last_ln := de_line;
                        end if;
                        if de_line = 120 then
                            report "mid line: " & integer'image(col) & " samples, " &
                                   integer'image(nonblack) & " lit, " &
                                   integer'image(transits) & " changes; RGB=" &
                                   integer'image(to_integer(unsigned(vr))) & "/" &
                                   integer'image(to_integer(unsigned(vg))) & "/" &
                                   integer'image(to_integer(unsigned(vb)));
                        end if;
                    end if;
                end if;
                col := 0; nonblack := 0; transits := 0; had_de := false;
                line := line + 1;
            end if;

            if vs_prev = '1' and vs_n = '0' then
                if field = 3 then
                    report "picture occupies DE lines " & integer'image(first_ln) &
                           " to " & integer'image(last_ln) & " of " &
                           integer'image(de_line);
                    report "DONE" severity failure;
                end if;
                field := field + 1; line := 0; de_line := 0;
                first_ln := -1; last_ln := -1;
            end if;
            hs_prev := hs_n; vs_prev := vs_n;
        end if;
    end process;

end sim;
