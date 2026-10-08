# Tools for the disassembly of the Power Macintosh 7600 ROM (see ../README.md).
# Run under WSL/Linux (g++ 13, GNU make):
#
#   make -C /mnt/c/Temp/mistercore/PPC_Mac/rom7600/tools [BUILD=<dir>] -j4
#
# The dingusppc, MAME and QEMU trees are only read; everything is built
# under $(BUILD).
#
#   ppcdis_dingus  dingusppc's PowerPC disassembler (the listings use it)
#   mamedis        MAME's 68k and PowerPC disassemblers (68k listings; PPC check)
#   bu68k          the binutils 68k disassembler from QEMU (68k check)
#   romcov         a headless dingusppc 7600 that records every executed word

DINGUS ?= /mnt/c/Temp/mistercore/dingusppc
MAME   ?= /mnt/c/Temp/mistercore/mame
QEMU   ?= /mnt/c/Temp/mistercore/qemu
BUILD  ?= $(HOME)/.cache/ppcmac/romdisasm/build
OPT    ?= -O2
CXX    ?= g++
CC     ?= gcc

SRC := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

.PHONY: all disasm clean
all: $(BUILD)/ppcdis_dingus $(BUILD)/mamedis $(BUILD)/bu68k $(BUILD)/romcov
disasm: $(BUILD)/ppcdis_dingus $(BUILD)/mamedis $(BUILD)/bu68k

# ---- dingusppc's disassembler ------------------------------------------------
$(BUILD)/ppcdis_dingus: $(SRC)/ppcdis_dingus.cpp $(DINGUS)/cpu/ppc/ppcdisasm.cpp
	@mkdir -p $(@D)
	$(CXX) -std=c++17 $(OPT) -w -I$(DINGUS) -o $@ $^

# ---- MAME's disassemblers ----------------------------------------------------
MAME_INC := -I$(SRC)/shim/mame -I$(BUILD)/shim -I$(MAME)/src/devices -I$(MAME)/src/lib/util -I$(MAME)/src/osd
MAME_SRC := $(MAME)/src/devices/cpu/m68000/m68kdasm.cpp $(MAME)/src/devices/cpu/powerpc/ppc_dasm.cpp \
            $(MAME)/src/lib/util/disasmintf.cpp $(MAME)/src/lib/util/strformat.cpp

$(BUILD)/shim/ppccom_sprs.h: $(MAME)/src/devices/cpu/powerpc/ppccom.h
	@mkdir -p $(@D)
	awk '/^\/\/ SPRs/{f=1} f{print} f&&/^};/{exit}' $< > $@

$(BUILD)/mamedis: $(SRC)/mamedis.cpp $(MAME_SRC) $(BUILD)/shim/ppccom_sprs.h $(SRC)/shim/mame/emu.h
	@mkdir -p $(@D)
	$(CXX) -std=c++20 $(OPT) -w $(MAME_INC) -o $@ $(SRC)/mamedis.cpp $(MAME_SRC)

# ---- binutils' 68k disassembler (QEMU's copy) --------------------------------
$(BUILD)/bu68k: $(SRC)/bu68k.c $(QEMU)/disas/m68k.c
	@mkdir -p $(@D)
	$(CC) -std=gnu11 $(OPT) -w -I$(SRC)/shim/qemu -I$(QEMU)/include -o $@ $^ -lm

# ---- coverage machine: dingusppc as verilator/machref builds it --------------
DIRS := cpu/ppc core devices devices/common devices/common/adb devices/common/ata \
        devices/common/clockgen devices/common/firewire devices/common/i2c \
        devices/common/nubus devices/common/pci devices/common/scsi devices/common/usb \
        devices/ethernet devices/floppy devices/ioctrl devices/memctrl devices/serial \
        devices/sound devices/storage devices/video machines utils
ALL_CPP    := $(foreach d,$(DIRS),$(wildcard $(DINGUS)/$(d)/*.cpp))
EXCLUDED   := $(DINGUS)/core/hostevents_sdl.cpp $(DINGUS)/devices/video/display_sdl.cpp \
              $(DINGUS)/devices/sound/soundserver_cubeb.cpp
DINGUS_CPP := $(filter-out $(EXCLUDED) %_js.cpp,$(ALL_CPP)) $(DINGUS)/thirdparty/loguru/loguru.cpp
DINGUS_OBJ := $(patsubst $(DINGUS)/%.cpp,$(BUILD)/dingus/%.o,$(DINGUS_CPP))
OWN_OBJ    := $(BUILD)/romcov.o $(BUILD)/null_host.o
DEFS  := -DSUPPORTS_PPC_LITTLE_ENDIAN_MODE=0 -DSUPPORTS_MEMORY_CTRL_ENDIAN_MODE=0 -DLOGURU_STACKTRACES=0
FLAGS := -std=c++20 $(OPT) -fno-strict-aliasing $(DEFS) -MMD -MP
INCS  := -I$(DINGUS) -I$(DINGUS)/devices -I$(DINGUS)/thirdparty/loguru

$(BUILD)/dingus/%.o: $(DINGUS)/%.cpp
	@mkdir -p $(@D)
	@$(CXX) $(FLAGS) -w $(INCS) -c $< -o $@

$(BUILD)/%.o: $(SRC)/%.cpp
	@mkdir -p $(@D)
	$(CXX) $(FLAGS) -Wall $(INCS) -c $< -o $@

$(BUILD)/romcov: $(OWN_OBJ) $(DINGUS_OBJ)
	$(CXX) -o $@ $(OWN_OBJ) $(DINGUS_OBJ) -lpthread
	@echo "built $@"

clean:
	rm -rf $(BUILD)

-include $(DINGUS_OBJ:.o=.d) $(OWN_OBJ:.o=.d)
