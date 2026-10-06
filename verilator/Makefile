# Verilator builds of the DSPPC604 test benches (run under WSL/Linux).
#
#   make            build $(BUILD)/vector_tb   single-instruction golden vectors
#   make core       build $(BUILD)/core/core_tb   programs on the pipeline
#   make cdc        build $(BUILD)/cdc/cdc_tb   the memory port across two clocks
#   make machine    build $(BUILD)/machine/machine_tb   the whole machine (PPCMac_system) running a ROM
#   make sdram      build $(BUILD)/sdram/sdram_tb   the SDRAM controller against a model of the board
#   make lint       Verilator lint only
#   make clean
#
# REF_LIB=<path to libdingusref.a> links the dingusppc reference into core_tb
# for lockstep runs. Normally driven by run.py and run_core.py.

VERILATOR ?= verilator
BUILD     ?= build
REF_LIB   ?=

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
	@$(VERILATOR) $(VFLAGS) --top-module PPCMac_system -Mdir $(MACH_DIR) -o machine_tb \
		-CFLAGS "-O2 -std=c++17 -DPPCMAC_MACHINE $(REF_CFLAGS)" $(REF_LDFLAGS) \
		$(RTL_SRCS) $(MACH_SRCS) $(HERE)core_main.cpp \
		> $(MACH_DIR)/build.log 2>&1 || (cat $(MACH_DIR)/build.log; false)
	@grep -E '^%Warning' $(MACH_DIR)/build.log || true

sdram: $(BUILD)/sdram/sdram_tb

$(BUILD)/sdram/sdram_tb: $(RTL)/DSPPC604_memcdc.sv $(MACH)/PPCMac_sdram.sv $(HERE)sdram_tb_top.sv $(HERE)sdram_main.cpp $(HERE)Makefile
	@mkdir -p $(BUILD)/sdram
	@$(VERILATOR) $(VFLAGS) --top-module sdram_tb_top -Mdir $(BUILD)/sdram -o sdram_tb \
		-CFLAGS "-O2 -std=c++17" \
		$(RTL)/DSPPC604_memcdc.sv $(MACH)/PPCMac_sdram.sv $(HERE)sdram_tb_top.sv $(HERE)sdram_main.cpp \
		> $(BUILD)/sdram/build.log 2>&1 || (cat $(BUILD)/sdram/build.log; false)
	@grep -E '^%Warning' $(BUILD)/sdram/build.log || true

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

clean:
	rm -rf $(BUILD)

.PHONY: all core machine sdram cdc lint clean
