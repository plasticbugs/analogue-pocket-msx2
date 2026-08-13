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

entity tb_scc_mg2 is end tb_scc_mg2;

architecture sim of tb_scc_mg2 is
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

        cpuwr(16#00#, 48);
        cpuwr(16#01#, 80);
        cpuwr(16#02#, 80);
        cpuwr(16#03#, 48);
        cpuwr(16#04#, 0);
        cpuwr(16#05#, 0);
        cpuwr(16#06#, 16);
        cpuwr(16#07#, 64);
        cpuwr(16#08#, 96);
        cpuwr(16#09#, 112);
        cpuwr(16#0A#, 96);
        cpuwr(16#0B#, 48);
        cpuwr(16#0C#, 240);
        cpuwr(16#0D#, 224);
        cpuwr(16#0E#, 224);
        cpuwr(16#0F#, 0);
        cpuwr(16#10#, 32);
        cpuwr(16#11#, 32);
        cpuwr(16#12#, 16);
        cpuwr(16#13#, 192);
        cpuwr(16#14#, 160);
        cpuwr(16#15#, 144);
        cpuwr(16#16#, 160);
        cpuwr(16#17#, 192);
        cpuwr(16#18#, 0);
        cpuwr(16#19#, 0);
        cpuwr(16#1A#, 208);
        cpuwr(16#1B#, 176);
        cpuwr(16#1C#, 176);
        cpuwr(16#1D#, 208);
        cpuwr(16#1E#, 0);
        cpuwr(16#1F#, 0);
        cpuwr(16#20#, 0);
        cpuwr(16#21#, 25);
        cpuwr(16#22#, 49);
        cpuwr(16#23#, 71);
        cpuwr(16#24#, 90);
        cpuwr(16#25#, 106);
        cpuwr(16#26#, 117);
        cpuwr(16#27#, 125);
        cpuwr(16#28#, 127);
        cpuwr(16#29#, 125);
        cpuwr(16#2A#, 117);
        cpuwr(16#2B#, 106);
        cpuwr(16#2C#, 90);
        cpuwr(16#2D#, 71);
        cpuwr(16#2E#, 49);
        cpuwr(16#2F#, 25);
        cpuwr(16#30#, 0);
        cpuwr(16#31#, 224);
        cpuwr(16#32#, 192);
        cpuwr(16#33#, 160);
        cpuwr(16#34#, 128);
        cpuwr(16#35#, 160);
        cpuwr(16#36#, 192);
        cpuwr(16#37#, 224);
        cpuwr(16#38#, 0);
        cpuwr(16#39#, 32);
        cpuwr(16#3A#, 64);
        cpuwr(16#3B#, 96);
        cpuwr(16#3C#, 127);
        cpuwr(16#3D#, 96);
        cpuwr(16#3E#, 64);
        cpuwr(16#3F#, 32);
        cpuwr(16#40#, 0);
        cpuwr(16#41#, 25);
        cpuwr(16#42#, 49);
        cpuwr(16#43#, 71);
        cpuwr(16#44#, 90);
        cpuwr(16#45#, 106);
        cpuwr(16#46#, 117);
        cpuwr(16#47#, 125);
        cpuwr(16#48#, 127);
        cpuwr(16#49#, 125);
        cpuwr(16#4A#, 117);
        cpuwr(16#4B#, 106);
        cpuwr(16#4C#, 90);
        cpuwr(16#4D#, 71);
        cpuwr(16#4E#, 49);
        cpuwr(16#4F#, 25);
        cpuwr(16#50#, 0);
        cpuwr(16#51#, 224);
        cpuwr(16#52#, 192);
        cpuwr(16#53#, 160);
        cpuwr(16#54#, 128);
        cpuwr(16#55#, 160);
        cpuwr(16#56#, 192);
        cpuwr(16#57#, 224);
        cpuwr(16#58#, 0);
        cpuwr(16#59#, 32);
        cpuwr(16#5A#, 64);
        cpuwr(16#5B#, 96);
        cpuwr(16#5C#, 127);
        cpuwr(16#5D#, 96);
        cpuwr(16#5E#, 64);
        cpuwr(16#5F#, 32);
        cpuwr(16#60#, 0);
        cpuwr(16#61#, 25);
        cpuwr(16#62#, 49);
        cpuwr(16#63#, 71);
        cpuwr(16#64#, 90);
        cpuwr(16#65#, 106);
        cpuwr(16#66#, 117);
        cpuwr(16#67#, 125);
        cpuwr(16#68#, 127);
        cpuwr(16#69#, 125);
        cpuwr(16#6A#, 117);
        cpuwr(16#6B#, 106);
        cpuwr(16#6C#, 90);
        cpuwr(16#6D#, 71);
        cpuwr(16#6E#, 49);
        cpuwr(16#6F#, 25);
        cpuwr(16#70#, 0);
        cpuwr(16#71#, 224);
        cpuwr(16#72#, 192);
        cpuwr(16#73#, 160);
        cpuwr(16#74#, 128);
        cpuwr(16#75#, 160);
        cpuwr(16#76#, 192);
        cpuwr(16#77#, 224);
        cpuwr(16#78#, 0);
        cpuwr(16#79#, 32);
        cpuwr(16#7A#, 64);
        cpuwr(16#7B#, 96);
        cpuwr(16#7C#, 127);
        cpuwr(16#7D#, 96);
        cpuwr(16#7E#, 64);
        cpuwr(16#7F#, 32);
        cpuwr(16#A0#, 0);
        cpuwr(16#A1#, 25);
        cpuwr(16#A2#, 49);
        cpuwr(16#A3#, 71);
        cpuwr(16#A4#, 90);
        cpuwr(16#A5#, 106);
        cpuwr(16#A6#, 117);
        cpuwr(16#A7#, 125);
        cpuwr(16#A8#, 127);
        cpuwr(16#A9#, 125);
        cpuwr(16#AA#, 117);
        cpuwr(16#AB#, 106);
        cpuwr(16#AC#, 90);
        cpuwr(16#AD#, 71);
        cpuwr(16#AE#, 49);
        cpuwr(16#AF#, 25);
        cpuwr(16#B0#, 0);
        cpuwr(16#B1#, 224);
        cpuwr(16#B2#, 192);
        cpuwr(16#B3#, 160);
        cpuwr(16#B4#, 128);
        cpuwr(16#B5#, 160);
        cpuwr(16#B6#, 192);
        cpuwr(16#B7#, 224);
        cpuwr(16#B8#, 0);
        cpuwr(16#B9#, 32);
        cpuwr(16#BA#, 64);
        cpuwr(16#BB#, 96);
        cpuwr(16#BC#, 127);
        cpuwr(16#BD#, 96);
        cpuwr(16#BE#, 64);
        cpuwr(16#BF#, 32);
        cpuwr(16#80#, 0);
        cpuwr(16#81#, 0);
        cpuwr(16#82#, 80);
        cpuwr(16#83#, 2);
        cpuwr(16#84#, 79);
        cpuwr(16#85#, 1);
        cpuwr(16#86#, 160);
        cpuwr(16#87#, 4);
        cpuwr(16#88#, 159);
        cpuwr(16#89#, 2);
        cpuwr(16#8A#, 0);
        cpuwr(16#8B#, 2);
        cpuwr(16#8C#, 2);
        cpuwr(16#8D#, 1);
        cpuwr(16#8E#, 1);
        cpuwr(16#8F#, 30);
        wait;
    end process;

    dump: process(clk21m)
        file f : text open write_mode is "scc_mg2_out.txt";
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
