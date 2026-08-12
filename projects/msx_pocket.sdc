# ==============================================================================
# Quartus Prime Synopsys Design Constraint File
# ==============================================================================
# MSX2 core constraints.
#
# The Pocket BSP (platform/pocket/bsp/pocket/sys_constr.sdc) declares the
# asynchronous clock groups for core_pll outputs 0-3. The MSX2 machine runs on
# a fifth output (outclk_4, 21.477MHz, general[4]), which the BSP predates, so
# it must be declared here or its crossings -- notably the data_io dcfifo from
# clk_74a and the asynchronous resets -- are left unconstrained.
# ==============================================================================

# ==============================================================================
# Set Clock Groups
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }
