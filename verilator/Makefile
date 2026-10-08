# Verilator builds of the DSPPC604 test benches (run under WSL/Linux).
#
#   make            build $(BUILD)/vector_tb   single-instruction golden vectors
#   make core       build $(BUILD)/core/core_tb   programs on the pipeline
#   make cdc        build $(BUILD)/cdc/cdc_tb   the memory port across two clocks
#   make machine    build $(BUILD)/machine/machine_tb   the whole machine (PPCMac_system) running a ROM
#   make gui        build $(BUILD)/gui/ppcmac_gui   the whole machine in a window (ImGui, SDL2, OpenGL)
#   make sdram      build $(BUILD)/sdram/sdram_tb   the SDRAM controller against a model of the board
#   make cuda       build $(BUILD)/cuda/cuda_tb   Cuda (the 68HC05 and its firmware) alone
#   make lint       Verilator lint only
#   make clean
#
# REF_LIB=<path to libdingusref.a> links the dingusppc reference into core_tb
# for lockstep runs. HC05_LIB=<path to libhc05ref.a> links MAME's 6805 core
# into cuda_tb. Normally driven by run.py, run_core.py and run_cuda.py.

VERILATOR ?= verilator
BUILD     ?= build
REF_LIB   ?=
HC05_LIB  ?=

HERE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL  := $(HERE)../rtl/DSPPC604

# the CPU's file list lives in its .qip, shared with Quartus
RTL_SRCS := $(addprefix $(RTL)/,$(shell grep -o '[A-Za-z0-9_]*\.sv' $(RTL)/DSPPC604.qip))

# the machine around it, likewise from its .qip
MACH     := $(HERE)../rtl/machine
MACH_SRCS := $(addprefix $(MACH)/,$(shell grep -o '[A-Za-z0-9_]*\.sv' $(MACH)/PPCMac_machine.qip))

# The RTL is kept clean under -Wall. Unused-signal warnings are off because a
# unit legitimately ignores most of the decode bundle it is handed.
WARN := -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM

VFLAGS := --cc --exe --build -j 0 $(WARN)

ifneq ($(REF_LIB),)
REF_CFLAGS  := -DWITH_REF -I$(HERE)ref
REF_LDFLAGS := -LDFLAGS "$(REF_LIB)"
CORE_DIR    := $(BUILD)/core_ref
MACH_DIR    := $(BUILD)/machine_ref
else
CORE_DIR    := $(BUILD)/core
MACH_DIR    := $(BUILD)/machine
endif

all: $(BUILD)/vector_tb

$(BUILD)/vector_tb: $(RTL_SRCS) $(HERE)vector_dut.sv $(HERE)sim_main.cpp $(RTL)/DSPPC604.qip $(HERE)Makefile
	@mkdir -p $(BUILD)
	@$(VERILATOR) $(VFLAGS) --top-module vector_dut -Mdir $(BUILD) -o vector_tb \
		-CFLAGS "-O2 -std=c++17" \
		$(RTL_SRCS) $(HERE)vector_dut.sv $(HERE)sim_main.cpp \
		> $(BUILD)/build.log 2>&1 || (cat $(BUILD)/build.log; false)
	@grep -E '^%Warning' $(BUILD)/build.log || true

core: $(CORE_DIR)/core_tb

$(CORE_DIR)/core_tb: $(RTL_SRCS) $(HERE)core_main.cpp $(RTL)/DSPPC604.qip $(HERE)Makefile $(REF_LIB)
	@mkdir -p $(CORE_DIR)
	@$(VERILATOR) $(VFLAGS) --top-module DSPPC604 -Mdir $(CORE_DIR) -o core_tb \
		-CFLAGS "-O2 -std=c++17 $(REF_CFLAGS)" $(REF_LDFLAGS) \
		$(RTL_SRCS) $(HERE)core_main.cpp \
		> $(CORE_DIR)/build.log 2>&1 || (cat $(CORE_DIR)/build.log; false)
	@grep -E '^%Warning' $(CORE_DIR)/build.log || true

machine: $(MACH_DIR)/machine_tb

$(MACH_DIR)/machine_tb: $(RTL_SRCS) $(MACH_SRCS) $(HERE)core_main.cpp $(RTL)/DSPPC604.qip $(MACH)/PPCMac_machine.qip $(HERE)Makefile $(REF_LIB)
	@mkdir -p $(MACH_DIR)
	@$(VERILATOR) $(VFLAGS) --top-module PPCMac_system -GCUDA_FAST_BOOT=1 -Mdir $(MACH_DIR) -o machine_tb \
		-CFLAGS "-O2 -std=c++17 -DPPCMAC_MACHINE $(REF_CFLAGS)" $(REF_LDFLAGS) \
		$(RTL_SRCS) $(MACH_SRCS) $(HERE)core_main.cpp \
		> $(MACH_DIR)/build.log 2>&1 || (cat $(MACH_DIR)/build.log; false)
	@grep -E '^%Warning' $(MACH_DIR)/build.log || true

# the machine in a window, with the framework the other cores' benches use
# (sim/: sim_video, sim_console and Dear ImGui with its SDL2 and OpenGL 2
# back ends, the template's files as they are); the machine built as
# machine_tb builds it
GUI_SRCS := $(HERE)gui_main.cpp $(HERE)sim/sim_video.cpp $(HERE)sim/sim_console.cpp \
	$(addprefix $(HERE)sim/imgui/,imgui.cpp imgui_draw.cpp imgui_widgets.cpp imgui_tables.cpp imgui_impl_sdl.cpp imgui_impl_opengl2.cpp)

gui: $(BUILD)/gui/ppcmac_gui

$(BUILD)/gui/ppcmac_gui: $(RTL_SRCS) $(MACH_SRCS) $(GUI_SRCS) $(RTL)/DSPPC604.qip $(MACH)/PPCMac_machine.qip $(HERE)Makefile
	@mkdir -p $(BUILD)/gui
	@$(VERILATOR) $(VFLAGS) --top-module PPCMac_system -GCUDA_FAST_BOOT=1 -Mdir $(BUILD)/gui -o ppcmac_gui \
		-CFLAGS "-O2 -std=c++17 -I$(HERE)sim -I$(HERE)sim/imgui $(shell sdl2-config --cflags)" \
		-LDFLAGS "$(shell sdl2-config --libs) -lGL" \
		$(RTL_SRCS) $(MACH_SRCS) $(GUI_SRCS) \
		> $(BUILD)/gui/build.log 2>&1 || (cat $(BUILD)/gui/build.log; false)
	@grep -E '^%Warning' $(BUILD)/gui/build.log || true

sdram: $(BUILD)/sdram/sdram_tb

$(BUILD)/sdram/sdram_tb: $(RTL)/DSPPC604_memcdc.sv $(MACH)/PPCMac_sdram.sv $(HERE)sdram_tb_top.sv $(HERE)sdram_main.cpp $(HERE)Makefile
	@mkdir -p $(BUILD)/sdram
	@$(VERILATOR) $(VFLAGS) --top-module sdram_tb_top -Mdir $(BUILD)/sdram -o sdram_tb \
		-CFLAGS "-O2 -std=c++17" \
		$(RTL)/DSPPC604_memcdc.sv $(MACH)/PPCMac_sdram.sv $(HERE)sdram_tb_top.sv $(HERE)sdram_main.cpp \
		> $(BUILD)/sdram/build.log 2>&1 || (cat $(BUILD)/sdram/build.log; false)
	@grep -E '^%Warning' $(BUILD)/sdram/build.log || true

# Cuda with the ADB devices on its line (cuda_tb_top), its clock at
# 2 x 4,194,304 Hz (the least PPCMac_cuda takes) to run fast
CUDA_SRCS := $(MACH)/PPCMac_hc05.sv $(MACH)/PPCMac_cudarom.sv $(MACH)/PPCMac_cuda.sv $(MACH)/PPCMac_adb.sv $(HERE)cuda_tb_top.sv
ifneq ($(HC05_LIB),)
CUDA_DIR    := $(BUILD)/cuda_ref
CUDA_CFLAGS := -DWITH_HC05REF -I$(HERE)hc05ref
CUDA_LDFLAGS := -LDFLAGS "$(HC05_LIB)"
else
CUDA_DIR    := $(BUILD)/cuda
endif

cuda: $(CUDA_DIR)/cuda_tb

$(CUDA_DIR)/cuda_tb: $(CUDA_SRCS) $(HERE)cuda_main.cpp $(HERE)Makefile $(HC05_LIB)
	@mkdir -p $(CUDA_DIR)
	@$(VERILATOR) $(VFLAGS) --top-module cuda_tb_top -GCLK_HZ=8388608 -Mdir $(CUDA_DIR) -o cuda_tb \
		-CFLAGS "-O2 -std=c++17 $(CUDA_CFLAGS)" $(CUDA_LDFLAGS) \
		$(CUDA_SRCS) $(HERE)cuda_main.cpp \
		> $(CUDA_DIR)/build.log 2>&1 || (cat $(CUDA_DIR)/build.log; false)
	@grep -E '^%Warning' $(CUDA_DIR)/build.log || true

# MESH, its DBDMA channel and the disks (scsi_tb_top), driven as the ROM and
# Mac OS drive them
SCSI_SRCS := $(MACH)/PPCMac_pkg.sv $(filter-out %PPCMac_pkg.sv %PPCMac_machine.sv %PPCMac_system.sv,$(MACH_SRCS)) $(HERE)scsi_tb_top.sv

scsi: $(BUILD)/scsi/scsi_tb

$(BUILD)/scsi/scsi_tb: $(SCSI_SRCS) $(HERE)scsi_main.cpp $(MACH)/PPCMac_machine.qip $(HERE)Makefile
	@mkdir -p $(BUILD)/scsi
	@$(VERILATOR) $(VFLAGS) --top-module scsi_tb_top -Mdir $(BUILD)/scsi -o scsi_tb \
		-CFLAGS "-O2 -std=c++17" \
		$(SCSI_SRCS) $(HERE)scsi_main.cpp \
		> $(BUILD)/scsi/build.log 2>&1 || (cat $(BUILD)/scsi/build.log; false)
	@grep -E '^%Warning' $(BUILD)/scsi/build.log || true

cdc: $(BUILD)/cdc/cdc_tb

$(BUILD)/cdc/cdc_tb: $(RTL)/DSPPC604_memcdc.sv $(HERE)cdc_main.cpp $(HERE)Makefile
	@mkdir -p $(BUILD)/cdc
	@$(VERILATOR) $(VFLAGS) --top-module DSPPC604_memcdc -Mdir $(BUILD)/cdc -o cdc_tb \
		-CFLAGS "-O2 -std=c++17" \
		$(RTL)/DSPPC604_memcdc.sv $(HERE)cdc_main.cpp \
		> $(BUILD)/cdc/build.log 2>&1 || (cat $(BUILD)/cdc/build.log; false)
	@grep -E '^%Warning' $(BUILD)/cdc/build.log || true

lint:
	$(VERILATOR) --lint-only $(WARN) --top-module vector_dut $(RTL_SRCS) $(HERE)vector_dut.sv
	$(VERILATOR) --lint-only $(WARN) --top-module DSPPC604 $(RTL_SRCS)
	$(VERILATOR) --lint-only $(WARN) --top-module DSPPC604_memcdc $(RTL)/DSPPC604_memcdc.sv
	$(VERILATOR) --lint-only $(WARN) --top-module PPCMac_system $(RTL_SRCS) $(MACH_SRCS)
	$(VERILATOR) --lint-only $(WARN) --top-module sdram_tb_top $(RTL)/DSPPC604_memcdc.sv $(MACH)/PPCMac_sdram.sv $(HERE)sdram_tb_top.sv
	$(VERILATOR) --lint-only $(WARN) --top-module PPCMac_debug $(MACH)/PPCMac_debug.sv
	$(VERILATOR) --lint-only $(WARN) --top-module PPCMac_nvsave $(MACH)/PPCMac_nvsave.sv
	$(VERILATOR) --lint-only $(WARN) --top-module cuda_tb_top $(CUDA_SRCS)
	$(VERILATOR) --lint-only $(WARN) --top-module scsi_tb_top $(SCSI_SRCS)

clean:
	rm -rf $(BUILD)

.PHONY: all core machine gui sdram cdc cuda scsi lint clean
