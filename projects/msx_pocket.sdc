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
# SDRAM interface (MT48LC16M16A2)
#
# The BSP's set_output_delay lines reference a clock named dram_clk that was
# never created, so Quartus silently ignored them: the entire SDRAM pin
# interface -- command/address/data setup at the chip and read-data capture
# -- was unconstrained and rerolled with every build. That was the
# nondeterministic cartridge corruption: the download stream checksummed
# clean while the SDRAM readback differed load to load.
#
# The SDRAM_CLK pin is driven by a DDIO cell that inverts the controller
# clock (the arrangement this controller has run in production on MiSTer
# for years); the chip's rising edge sits half a period after ours. With
# the interface registers packed into the I/O cells, the paths are short
# and deterministic, and the CL2 read capture is a two-cycle transfer.
# ==============================================================================
create_generated_clock -name dram_clk \
    -source [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -invert [get_ports {dram_clk}]

# The BSP's identical output delays run BEFORE this file creates dram_clk
# (SDC files process in order), so they are still ignored there; they must
# be restated here. tDS setup 1.5ns, tDH hold 0.8ns at the chip.
set_output_delay -clock dram_clk -max 1.5 [get_ports {dram_a[*] dram_ba[*] dram_cke dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -clock dram_clk -min -0.8 [get_ports {dram_a[*] dram_ba[*] dram_cke dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]

# tAC(CL2) max 5.4ns (-7E speed grade), tOH min 2.5ns
set_input_delay -clock dram_clk -max 5.4 [get_ports {dram_dq[*]}]
set_input_delay -clock dram_clk -min 2.5 [get_ports {dram_dq[*]}]

# CL2: the controller captures read data two of its cycles after the chip's
# launch edge
set_multicycle_path -setup -end 2 -from [get_clocks {dram_clk}] \
    -to [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold -end 1 -from [get_clocks {dram_clk}] \
    -to [get_clocks {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]

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
          ic|core_pll|core_pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk \
          dram_clk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }
