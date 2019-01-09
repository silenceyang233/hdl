
create_bd_intf_port -mode Master -vlnv analog.com:interface:spi_master_rtl:1.0 ad40xx_spi


## To support the 1.8MSPS (SCLK == 100 MHz), set the spi clock to 200 MHz
set_property -dict [list \
   CONFIG.PCW_EN_CLK2_PORT {1} \
   CONFIG.PCW_FPGA2_PERIPHERAL_FREQMHZ $spi_clk_ref_frequency] [get_bd_cells sys_ps7]

# create a SPI Engine architecture

create_bd_cell -type hier spi_ad40xx
current_bd_instance /spi_ad40xx

  create_bd_pin -dir I -type clk clk
  create_bd_pin -dir I -type rst resetn
  create_bd_pin -dir I -type clk spi_clk
  create_bd_pin -dir O irq
  create_bd_intf_pin -mode Master -vlnv analog.com:interface:spi_master_rtl:1.0 m_spi
  # Master AXI Stream interface
  create_bd_pin -dir O m_axis_tvalid
  create_bd_pin -dir I m_axis_tready
  create_bd_pin -dir O -from 31 -to 0 m_axis_tdata

  ad_ip_instance spi_engine_execution execution
  ad_ip_parameter execution CONFIG.DATA_WIDTH $adc_resolution
  ad_ip_parameter execution CONFIG.NUM_OF_CS 1
  ad_ip_parameter execution CONFIG.NUM_OF_SDI 1
  ad_ip_parameter execution CONFIG.SDO_DEFAULT 1

  ad_ip_instance axi_spi_engine axi
  ad_ip_parameter axi CONFIG.DATA_WIDTH $adc_resolution
  ad_ip_parameter axi CONFIG.NUM_OFFLOAD 1
  ad_ip_parameter axi CONFIG.ASYNC_SPI_CLK 1

  ad_ip_instance spi_engine_offload offload
  ad_ip_parameter offload CONFIG.DATA_WIDTH $adc_resolution
  ad_ip_parameter offload CONFIG.ASYNC_SPI_CLK 1

  ad_ip_instance spi_engine_interconnect interconnect
  ad_ip_parameter interconnect CONFIG.DATA_WIDTH $adc_resolution

  ad_ip_instance util_pulse_gen trigger_gen

  ## to setup the sample rate of the system change the PULSE_PERIOD value
  ## the acutal sample rate will be PULSE_PERIOD * (1/sys_cpu_clk)
  set sampling_cycle [expr int(ceil(double($spi_clk_ref_frequency * 1000000) / $adc_sampling_rate))]
  ad_ip_parameter trigger_gen CONFIG.PULSE_PERIOD $sampling_cycle
  ad_ip_parameter trigger_gen CONFIG.PULSE_WIDTH 1

  if {$adc_resolution != 16} {
    ad_ip_instance util_axis_upscale axis_upscaler
    ad_ip_parameter axis_upscaler CONFIG.NUM_OF_CHANNELS 1
    ad_ip_parameter axis_upscaler CONFIG.DATA_WIDTH $adc_resolution
    ad_ip_parameter axis_upscaler CONFIG.UDATA_WIDTH 32
    ad_connect axis_upscaler/dfmt_enable VCC
    ad_connect axis_upscaler/dfmt_type GND
    ad_connect axis_upscaler/dfmt_se VCC
  }

  ad_connect axi/spi_engine_offload_ctrl0 offload/spi_engine_offload_ctrl
  ad_connect offload/spi_engine_ctrl interconnect/s0_ctrl
  ad_connect axi/spi_engine_ctrl interconnect/s1_ctrl
  ad_connect interconnect/m_ctrl execution/ctrl

  if {$adc_resolution != 16} {
    ad_connect offload/offload_sdi axis_upscaler/s_axis
    ad_connect axis_upscaler/m_axis_valid m_axis_tvalid
    ad_connect axis_upscaler/m_axis_ready m_axis_tready
    ad_connect axis_upscaler/m_axis_data m_axis_tdata

    ad_connect spi_clk axis_upscaler/clk
    ad_connect axi/spi_resetn axis_upscaler/resetn
  } else {
    ad_connect offload/offload_sdi_tready m_axis_tready
    ad_connect offload/offload_sdi_tvalid m_axis_tvalid
    ad_connect offload/offload_sdi_tdata m_axis_tdata
  }

  ad_connect execution/spi m_spi

  ad_connect spi_clk offload/spi_clk
  ad_connect clk offload/ctrl_clk
  ad_connect spi_clk execution/clk
  ad_connect clk axi/s_axi_aclk
  ad_connect spi_clk axi/spi_clk
  ad_connect spi_clk interconnect/clk
  ad_connect spi_clk trigger_gen/clk

  ad_connect axi/spi_resetn offload/spi_resetn
  ad_connect axi/spi_resetn execution/resetn
  ad_connect axi/spi_resetn interconnect/resetn
  ad_connect axi/spi_resetn trigger_gen/rstn
  ad_connect trigger_gen/pulse_period_en GND
  ad_connect trigger_gen/pulse_period GND

  ad_connect trigger_gen/pulse offload/trigger

  ad_connect resetn axi/s_axi_aresetn
  ad_connect irq axi/irq

current_bd_instance /

# asynchronous SPI clock, to support higher SCLK
ad_connect spi_clk sys_ps7/FCLK_CLK2

# dma to receive data stream

ad_ip_instance axi_dmac axi_ad40xx_dma
ad_ip_parameter axi_ad40xx_dma CONFIG.DMA_TYPE_SRC 1
ad_ip_parameter axi_ad40xx_dma CONFIG.DMA_TYPE_DEST 0
ad_ip_parameter axi_ad40xx_dma CONFIG.CYCLIC 0
ad_ip_parameter axi_ad40xx_dma CONFIG.SYNC_TRANSFER_START 0
ad_ip_parameter axi_ad40xx_dma CONFIG.AXI_SLICE_SRC 0
ad_ip_parameter axi_ad40xx_dma CONFIG.AXI_SLICE_DEST 1
ad_ip_parameter axi_ad40xx_dma CONFIG.DMA_2D_TRANSFER 0

if {$adc_resolution != 16} {
  ad_ip_parameter axi_ad40xx_dma CONFIG.DMA_DATA_WIDTH_SRC 32
} else {
  ad_ip_parameter axi_ad40xx_dma CONFIG.DMA_DATA_WIDTH_SRC 16
}
ad_ip_parameter axi_ad40xx_dma CONFIG.DMA_DATA_WIDTH_DEST 64

ad_connect  sys_cpu_clk spi_ad40xx/clk
ad_connect  spi_clk axi_ad40xx_dma/s_axis_aclk
ad_connect  sys_cpu_resetn spi_ad40xx/resetn
ad_connect  sys_cpu_resetn axi_ad40xx_dma/m_dest_axi_aresetn

ad_connect  spi_clk spi_ad40xx/spi_clk

ad_connect  spi_ad40xx/m_spi ad40xx_spi

## If offload is active and the DMA can not receive data, samples will be dropped
## to ensure that every sample is the latest
## We can achieve this by connecting the SPI Engine's AXI stream ready port to VCC
ad_connect  axi_ad40xx_dma/s_axis_valid spi_ad40xx/m_axis_tvalid
ad_connect  axi_ad40xx_dma/s_axis_data spi_ad40xx/m_axis_tdata
ad_connect  spi_ad40xx/m_axis_tready VCC

ad_cpu_interconnect 0x44a00000 spi_ad40xx/axi
ad_cpu_interconnect 0x44a30000 axi_ad40xx_dma

ad_cpu_interrupt "ps-13" "mb-13" axi_ad40xx_dma/irq
ad_cpu_interrupt "ps-12" "mb-12" /spi_ad40xx/irq

ad_mem_hp2_interconnect sys_cpu_clk sys_ps7/S_AXI_HP2
ad_mem_hp2_interconnect sys_cpu_clk axi_ad40xx_dma/m_dest_axi

