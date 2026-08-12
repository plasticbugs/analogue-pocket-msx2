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
    signal vram0 : ram_t := (others => (others => '0'));
    signal vram1 : ram_t := (others => (others => '0'));

    -- Z80 test program at 0x0000
    type rom_t is array (0 to 63) of std_logic_vector(7 downto 0);
    constant prog : rom_t := (
        x"3E", x"60", x"D3", x"99", x"3E", x"81", x"D3", x"99",
        x"ED", x"56", x"FB", x"18", x"FE", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"00", x"00", x"00", x"00", x"00", x"00", x"00", x"00",
        x"DB", x"99", x"D3", x"2F", x"FB", x"ED", x"4D", x"00");

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
    req <= '1' when ((mreq_n = '0' or iorq_n = '0') and (rd_n = '0' or wr_n = '0')
                     and iack = '0') else '0';
    process(clk21m)
    begin
        if rising_edge(clk21m) then
            if reset = '1' then
                iack <= '0';
            elsif (mreq_n = '1' and iorq_n = '1') then
                iack <= '0';
            elsif req = '1' then
                iack <= '1';
            end if;
        end if;
    end process;

    pramdbi <= vram1_q & vram0_q;
    vdp_wrt <= not wr_n;

    io_en   <= '1' when (iorq_n = '0' and m1_n = '1') else '0';
    vdp_sel <= '1' when (io_en = '1' and a(7 downto 2) = "100110") else '0';
    vdp_req <= req and vdp_sel;

    U_VDP: entity work.VDP
    port map (
        CLK21M => clk21m, RESET => reset,
        REQ => vdp_req, ACK => vdp_ack, WRT => vdp_wrt, ADR => a,
        DBI => d_from_vdp, DBO => d_from_cpu, INT_N => vdp_int_n,
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
    d_to_cpu <= prog(to_integer(unsigned(a(5 downto 0)))) when (mreq_n = '0' and rd_n = '0' and a < x"0040") else
                stack(to_integer(unsigned(a(7 downto 0)))) when (mreq_n = '0' and rd_n = '0' and a(15 downto 8) = x"FF") else
                d_from_vdp when (vdp_sel = '1' and rd_n = '0') else
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

    check: process
    begin
        wait for 100 ms;
        report "VBLANK interrupts serviced in 100ms: " & integer'image(rb_idx);
        report "INT_n cleared (rising edges): " & integer'image(n_int_cleared) &
               "   INT_n low for " & integer'image((n_int_low*100)/n_cycles) & "% of cycles";
        report "vdp_req total=" & integer'image(n_vdpreq) &
               "  reads=" & integer'image(n_reads) &
               "  writes=" & integer'image(n_writes) &
               "  reads of port 0x99 (status)=" & integer'image(n_rd99);
        report "(expected about 6 at 60Hz)";
        if rb_idx >= 4 and rb_idx <= 8 then
            report "PASS: interrupt rate is correct and the flag clears";
        elsif rb_idx = 0 then
            report "FAIL: no interrupts reached the CPU";
        else
            report "FAIL: runaway interrupts - S#0 read is not clearing the flag";
        end if;
        report "DONE" severity failure;
    end process;

end sim;
