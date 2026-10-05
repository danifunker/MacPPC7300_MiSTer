# Verilator build of the golden-vector replay harness (run under WSL/Linux).
#
#   make            build $(BUILD)/vector_tb
#   make lint       Verilator lint only
#   make clean
#
# Normally driven by run.py, which also runs the result.

VERILATOR ?= verilator
BUILD     ?= build

HERE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL  := $(HERE)../rtl/DSPPC604

# the CPU's file list lives in its .qip, shared with Quartus
RTL_SRCS := $(addprefix $(RTL)/,$(shell grep -o '[A-Za-z0-9_]*\.sv' $(RTL)/DSPPC604.qip))

SRCS := $(RTL_SRCS) $(HERE)vector_dut.sv
MAIN := $(HERE)sim_main.cpp

# The RTL is kept clean under -Wall. Unused-signal warnings are off because a
# unit legitimately ignores most of the decode bundle it is handed.
WARN := -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM

VFLAGS := --cc --exe --build -j 0 $(WARN) \
	--top-module vector_dut \
	-Mdir $(BUILD) -o vector_tb \
	-CFLAGS "-O2 -std=c++17"

all: $(BUILD)/vector_tb

$(BUILD)/vector_tb: $(SRCS) $(MAIN) $(RTL)/DSPPC604.qip $(HERE)Makefile
	@mkdir -p $(BUILD)
	@$(VERILATOR) $(VFLAGS) $(SRCS) $(MAIN) > $(BUILD)/build.log 2>&1 || (cat $(BUILD)/build.log; false)
	@grep -E '^%Warning' $(BUILD)/build.log || true

lint:
	$(VERILATOR) --lint-only $(WARN) --top-module vector_dut $(SRCS)

clean:
	rm -rf $(BUILD)

.PHONY: all lint clean
