-- SCC listening test: drive scc_wave through the same address transform and
-- held-request strobes cart_konami_scc produces, program a sawtooth on
-- channel A, and log the wave output at the 3.58MHz sample rate. The
-- analyser checks period and shape against the K051649 formula:
-- step period = (freq+1) clkena ticks, 32 steps per cycle.
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.conv_std_logic_vector;
use std.textio.all;

entity tb_scc is end tb_scc;

architecture sim of tb_scc is
    signal clk21m : std_logic := '0';
    signal reset  : std_logic := '1';
    signal clkena : std_logic := '0';
    signal req    : std_logic := '0';
    signal ack    : std_logic;
    signal wrt    : std_logic := '0';
    signal adr    : std_logic_vector(7 downto 0) := (others => '0');
    signal dbi    : std_logic_vector(7 downto 0);
    signal dbo    : std_logic_vector(7 downto 0) := (others => '0');
    signal wave   : std_logic_vector(14 downto 0);
begin
    clk21m <= not clk21m after 23.283 ns;
    reset  <= '1', '0' after 1 us;

    -- 3.58MHz single-clock enable (every 6th clk21m)
    process(clk21m)
        variable div : integer := 0;
    begin
        if rising_edge(clk21m) then
            if div = 5 then
                div    := 0;
                clkena <= '1';
            else
                div    := div + 1;
                clkena <= '0';
            end if;
        end if;
    end process;

    U_SCC: entity work.scc_wave
    port map (
        clk21m => clk21m, reset => reset, clkena => clkena,
        req => req, ack => ack, wrt => wrt, adr => adr,
        dbi => dbi, dbo => dbo, wave => wave
    );

    stim: process
        -- CPU write at 0x9800+off through the cart_konami_scc address
        -- transform, with req held 8 clocks as a real CPU strobe is
        procedure cpuwr(off : in integer; val : in integer) is
            variable a : std_logic_vector(7 downto 0);
        begin
            a := conv_std_logic_vector(off, 8);
            if a(7) = '1' then
                a := a xor x"20";
            end if;
            wait until rising_edge(clk21m);
            adr <= a;
            dbo <= conv_std_logic_vector(val, 8);
            wrt <= '1';
            req <= '1';
            for i in 0 to 7 loop
                wait until rising_edge(clk21m);
            end loop;
            req <= '0';
            wrt <= '0';
            for i in 0 to 40 loop
                wait until rising_edge(clk21m);
            end loop;
        end procedure;
    begin
        wait until reset = '0';
        for i in 0 to 100 loop
            wait until rising_edge(clk21m);
        end loop;

        -- channel A waveform: 32-step sawtooth -128..+120
        for i in 0 to 31 loop
            cpuwr(i, (i*8 - 128) mod 256);
        end loop;
        cpuwr(16#80#, 16#6F#);  -- freq A low  (F=0x06F -> 112 ticks/step)
        cpuwr(16#81#, 16#00#);  -- freq A high
        cpuwr(16#8A#, 16#0F#);  -- volume A = 15
        cpuwr(16#8F#, 16#01#);  -- enable channel A
        wait;
    end process;

    dump: process(clk21m)
        file f : text open write_mode is "scc_out.txt";
        variable l : line;
        variable started : boolean := false;
    begin
        if rising_edge(clk21m) and reset = '0' then
            if clkena = '1' then
                if wave(14) = '1' then write(l, conv_integer(wave) - 32768); else write(l, conv_integer(wave)); end if;
                writeline(f, l);
            end if;
        end if;
    end process;
end sim;
