// Stand-in for MAME's emu.h, with only what its disassemblers need
// (the integer types, BIT, string_format and the disassembler interface).
#pragma once

#include "osdcomm.h"
#include "coretmpl.h"
#include "strformat.h"
#include "disasmintf.h"

#include <ostream>
#include <string>

using osd::u8;
using osd::u16;
using osd::u32;
using osd::u64;
using osd::s8;
using osd::s16;
using osd::s32;
using osd::s64;
typedef u32 offs_t;

using util::BIT;
using util::string_format;
