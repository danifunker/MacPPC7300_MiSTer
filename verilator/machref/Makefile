# machref - a whole dingusppc machine, headless, logging every device access
# (see machref.cpp). The dingusppc tree is only read; everything is built
# under $(BUILD).
#
#   make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/machref [BUILD=<dir>] [DINGUS=<dir>]
#
# Run under WSL/Linux (g++ 13, GNU make). No SDL, no cubeb: null_host.cpp
# stands in for the files that need them.

DINGUS ?= /mnt/c/Temp/mistercore/dingusppc
BUILD  ?= $(HOME)/.cache/macppc7300/machref
OPT    ?= -O2
CXX    ?= g++

SRC := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

ifeq ($(filter clean,$(MAKECMDGOALS)),)
ifeq ($(wildcard $(DINGUS)/cpu/ppc/ppcemu.h),)
$(error dingusppc tree not found at DINGUS=$(DINGUS))
endif
endif

ifeq ($(filter -j%,$(MAKEFLAGS)),)
MAKEFLAGS += -j$(shell nproc 2>/dev/null || echo 4)
endif

# dingusppc's sources as its CMake files collect them (cpu/ppc, core,
# devices, machines, utils, loguru), less the SDL, cubeb and Emscripten
# host files and its two main files
DIRS := cpu/ppc core devices devices/common devices/common/adb devices/common/ata \
        devices/common/clockgen devices/common/firewire devices/common/i2c \
        devices/common/nubus devices/common/pci devices/common/scsi devices/common/usb \
        devices/ethernet devices/floppy devices/ioctrl devices/memctrl devices/serial \
        devices/sound devices/storage devices/video machines utils
ALL_CPP   := $(foreach d,$(DIRS),$(wildcard $(DINGUS)/$(d)/*.cpp))
EXCLUDED  := $(DINGUS)/core/hostevents_sdl.cpp $(DINGUS)/devices/video/display_sdl.cpp \
             $(DINGUS)/devices/sound/soundserver_cubeb.cpp
DINGUS_CPP := $(filter-out $(EXCLUDED) %_js.cpp,$(ALL_CPP)) $(DINGUS)/thirdparty/loguru/loguru.cpp
DINGUS_OBJ := $(patsubst $(DINGUS)/%.cpp,$(BUILD)/dingus/%.o,$(DINGUS_CPP))
OWN_OBJ    := $(BUILD)/machref.o $(BUILD)/null_host.o

DEFS  := -DSUPPORTS_PPC_LITTLE_ENDIAN_MODE=0 -DSUPPORTS_MEMORY_CTRL_ENDIAN_MODE=0 -DLOGURU_STACKTRACES=0
FLAGS := -std=c++20 $(OPT) -fno-strict-aliasing $(DEFS) -MMD -MP
INCS  := -I$(DINGUS) -I$(DINGUS)/devices -I$(DINGUS)/thirdparty/loguru

.PHONY: all clean
all: $(BUILD)/machref

$(BUILD)/dingus/%.o: $(DINGUS)/%.cpp $(SRC)/Makefile
	@mkdir -p $(@D)
	@$(CXX) $(FLAGS) -w $(INCS) -c $< -o $@

$(BUILD)/%.o: $(SRC)/%.cpp $(SRC)/Makefile
	@mkdir -p $(@D)
	$(CXX) $(FLAGS) -Wall $(INCS) -c $< -o $@

$(BUILD)/machref: $(OWN_OBJ) $(DINGUS_OBJ)
	$(CXX) -o $@ $(OWN_OBJ) $(DINGUS_OBJ) -lpthread
	@echo "built $@"

clean:
	rm -rf $(BUILD)

-include $(DINGUS_OBJ:.o=.d) $(OWN_OBJ:.o=.d)
