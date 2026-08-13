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
#
# The machine clock (general[4], 21.477MHz), the pixel clocks (general[1]
# and [2], 10.738MHz) and the SDRAM clock (general[3], 85.909MHz = exactly
# 4x the machine clock) are deliberately kept in ONE group: the video output
# is launched on the machine clock and sampled by the APF scaler on the pixel
# clock, and the cartridge-ROM SDRAM interface crosses machine<->SDRAM every
# access. All these clocks are integer-related outputs of the same PLL, so
# the crossings are synchronous by construction and must be verified, not
# cut -- cutting the SDRAM crossing let each build route it blind, making
# MegaROM games (heavy SDRAM traffic) work or crash depending on the seed.
# The pixel clock is phase shifted half a machine-clock period in the
# PLL so it samples mid-pixel rather than on the edge where the VDP changes it.
# ==============================================================================

# ==============================================================================
# Set Clock Groups
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }
