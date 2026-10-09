# libdingusref.a - dingusppc's PowerPC interpreter behind the C API of dingus_ref.h
#
#   make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/ref [BUILD=<dir>] [DINGUS=<dir>]
#   make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/ref selftest
#
# Run under WSL/Linux (g++ 13, GNU make, binutils). Nothing is written outside
# $(BUILD); the dingusppc tree is only read.

DINGUS ?= /mnt/c/Temp/mistercore/dingusppc
BUILD  ?= $(HOME)/.cache/macppc7300/dingusref
OPT    ?= -O2
# 1: keep only the ref_* C API visible in the library, so dingusppc's many
#    generically named globals (ppc_state, power_on, ...) cannot clash with the
#    test bench. 0: plain archive of the individual objects.
HIDE   ?= 1

CXX     ?= g++
AR      ?= ar
LD      ?= ld
OBJCOPY ?= objcopy

SRC := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

ifeq ($(filter clean,$(MAKECMDGOALS)),)
ifeq ($(wildcard $(DINGUS)/cpu/ppc/ppcemu.h),)
$(error dingusppc tree not found at DINGUS=$(DINGUS))
endif
endif

# Compile in parallel unless the caller already chose a -j.
ifeq ($(filter -j%,$(MAKEFLAGS)),)
MAKEFLAGS += -j$(shell nproc 2>/dev/null || echo 4)
endif

# dingusppc is built the way its own CMake builds it (C++20, both little-endian
# options off). Added here: no stack traces in loguru (no libdl/execinfo use),
# -fno-strict-aliasing (lfs/stfs pun float/uint32_t through pointers) and
# -ffp-contract=off (same FP results whatever -march is added through OPT).
DEFS  := -DSUPPORTS_PPC_LITTLE_ENDIAN_MODE=0 -DSUPPORTS_MEMORY_CTRL_ENDIAN_MODE=0 \
         -DLOGURU_STACKTRACES=0
FLAGS := -std=c++20 $(OPT) -fno-strict-aliasing -ffp-contract=off $(DEFS) -MMD -MP

# Store logging: in the files that implement instructions, every call to the
# MMU's store functions is redirected to wrappers in dingus_ref.cpp.
HOOKS := -Dmmu_write_vmem=ref_hook_write_vmem -Dmmu_dcbz=ref_hook_dcbz

DINGUS_HOOKED := cpu/ppc/ppcopcodes cpu/ppc/ppcfpopcodes cpu/ppc/poweropcodes
DINGUS_PLAIN  := cpu/ppc/ppcexec cpu/ppc/ppcmmu cpu/ppc/ppcexceptions \
                 devices/memctrl/memctrlbase core/timermanager \
                 thirdparty/loguru/loguru

OBJ_HOOKED := $(DINGUS_HOOKED:%=$(BUILD)/dingus/%.o)
OBJ_PLAIN  := $(DINGUS_PLAIN:%=$(BUILD)/dingus/%.o)
OBJS       := $(BUILD)/dingus_ref.o $(OBJ_HOOKED) $(OBJ_PLAIN)

LIB      := $(BUILD)/libdingusref.a
SELFTEST := $(BUILD)/selftest

.PHONY: all selftest clean
all: $(LIB)

$(OBJ_HOOKED): EXTRA := $(HOOKS)

# dingusppc's own warnings (printf formats in log calls, mostly) are not ours
# to fix: -w. The files of this directory are compiled with warnings on.
$(BUILD)/dingus/%.o: $(DINGUS)/%.cpp $(SRC)/Makefile
	@mkdir -p $(@D)
	$(CXX) $(FLAGS) -w -I$(DINGUS) -I$(DINGUS)/thirdparty/loguru $(EXTRA) -c $< -o $@

$(BUILD)/%.o: $(SRC)/%.cpp $(SRC)/Makefile
	@mkdir -p $(@D)
	$(CXX) $(FLAGS) -Wall -Wextra -I$(SRC) -isystem $(DINGUS) -isystem $(DINGUS)/thirdparty/loguru -c $< -o $@

ifeq ($(HIDE),1)
# One relocatable object; every global symbol except ref_* is made local.
$(BUILD)/dingusref_all.o: $(OBJS)
	$(LD) -r --force-group-allocation -o $@ $(OBJS)
	$(OBJCOPY) -w --keep-global-symbol='ref_*' $@

$(LIB): $(BUILD)/dingusref_all.o
	@rm -f $@
	$(AR) rcs $@ $<
	@echo "built $@"
else
$(LIB): $(OBJS)
	@rm -f $@
	$(AR) rcs $@ $(OBJS)
	@echo "built $@"
endif

$(SELFTEST): $(BUILD)/selftest.o $(LIB)
	$(CXX) -o $@ $(BUILD)/selftest.o $(LIB)

selftest: $(SELFTEST)
	$(SELFTEST)

clean:
	rm -rf $(BUILD)/dingus $(BUILD)/*.o $(BUILD)/*.d $(LIB) $(SELFTEST)

-include $(OBJS:.o=.d) $(BUILD)/selftest.d
