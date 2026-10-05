# Verilator builds of the DSPPC604 test benches (run under WSL/Linux).
#
#   make            build $(BUILD)/vector_tb   single-instruction golden vectors
#   make core       build $(BUILD)/core/core_tb   programs on the pipeline
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

# The RTL is kept clean under -Wall. Unused-signal warnings are off because a
# unit legitimately ignores most of the decode bundle it is handed.
WARN := -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM

VFLAGS := --cc --exe --build -j 0 $(WARN)

ifneq ($(REF_LIB),)
REF_CFLAGS  := -DWITH_REF -I$(HERE)ref
REF_LDFLAGS := -LDFLAGS "$(REF_LIB)"
CORE_DIR    := $(BUILD)/core_ref
else
CORE_DIR    := $(BUILD)/core
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

lint:
	$(VERILATOR) --lint-only $(WARN) --top-module vector_dut $(RTL_SRCS) $(HERE)vector_dut.sv
	$(VERILATOR) --lint-only $(WARN) --top-module DSPPC604 $(RTL_SRCS)

clean:
	rm -rf $(BUILD)

.PHONY: all core lint clean
