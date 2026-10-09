# libhc05ref.a - MAME's 6805 core (the 68HC05's tables) behind the C API of hc05_ref.h
#
#   make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/hc05ref [BUILD=<dir>] [MAME=<dir>]
#
# Run under WSL/Linux (g++ 13, GNU make, binutils). Nothing is written outside
# $(BUILD); the MAME tree is only read (two files of src/devices/cpu/m6805).

MAME   ?= /mnt/c/Temp/mistercore/mame
BUILD  ?= $(HOME)/.cache/macppc7300/hc05ref
OPT    ?= -O2

CXX ?= g++
AR  ?= ar

SRC := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
M6805 := $(MAME)/src/devices/cpu/m6805

ifeq ($(filter clean,$(MAKECMDGOALS)),)
ifeq ($(wildcard $(M6805)/6805ops.hxx),)
$(error MAME tree not found at MAME=$(MAME))
endif
endif

LIB := $(BUILD)/libhc05ref.a

.PHONY: all clean
all: $(LIB)

# MAME's two files are included, not ours to warn about: -isystem
$(BUILD)/hc05_ref.o: $(SRC)/hc05_ref.cpp $(SRC)/hc05_ref.h $(M6805)/6805ops.hxx $(M6805)/m6805defs.h $(SRC)/Makefile
	@mkdir -p $(@D)
	$(CXX) -std=c++17 $(OPT) -Wall -Wextra -I$(SRC) -isystem $(M6805) -c $< -o $@

$(LIB): $(BUILD)/hc05_ref.o
	@rm -f $@
	$(AR) rcs $@ $<
	@echo "built $@"

clean:
	rm -rf $(BUILD)/*.o $(LIB)
