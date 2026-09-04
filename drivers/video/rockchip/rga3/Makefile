# SPDX-License-Identifier: GPL-2.0

ccflags-y += -I$(src) -I$(src)/include

rga_multicore-y := rga_drv.o rga_common.o rga3_reg_info.o rga_iommu.o rga_dma_buf.o \
	   rga_job.o rga_hw_config.o rga2_reg_info.o rga_policy.o rga_mm.o \
	   rga_fence.o rga_trace.o
rga_multicore-$(CONFIG_ROCKCHIP_RGA_DEBUGGER) += rga_debugger.o

obj-$(CONFIG_ROCKCHIP_MULTI_RGA) += rga_multicore.o
