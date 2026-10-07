/*
 * null_host.cpp - the host side of dingusppc with nothing behind it: no
 * window, no input, no sound. Replaces display_sdl.cpp, hostevents_sdl.cpp,
 * soundserver_cubeb.cpp and main_sdl.cpp, so that a whole dingusppc machine
 * links without SDL or cubeb. dingusppc's own sources are compiled unmodified.
 *
 * dingusppc is GPL-3.0-or-later; so is this program.
 */

#include <core/hostevents.h>
#include <core/timermanager.h>
#include <devices/common/dmacore.h>
#include <devices/sound/soundserver.h>
#include <devices/video/display.h>

#include <cstdint>
#include <cstdio>
#include <functional>
#include <memory>
#include <string>
#include <vector>

/* ---- globals the SDL files define ---------------------------------------- */

bool g_swap_command_option = false;   // core/hostevents_sdl.cpp
bool g_auto_grab_mouse     = false;   // devices/video/display_sdl.cpp

/* ---- display: shows nothing; writes one frame when asked ---------------------
   machref --frame-at N --frame-out FILE: at the first refresh after N
   instructions, the frame the video controller's converter makes (with the
   hardware cursor drawn over it when it is on), as a PPM. */

extern uint64_t g_icycles;    // cpu/ppc/ppcexec.cpp: instructions executed

uint64_t    g_frame_at = 0;
std::string g_frame_out;

static int  g_fw = 0, g_fh = 0;
static bool g_frame_done = false;
static bool g_cursor_on = false;
static std::function<void(uint8_t *, int)> g_convert, g_overlay;

static void frame_check() {
    if (g_frame_out.empty() || g_frame_done || g_icycles < g_frame_at || !g_convert || g_fw <= 0 || g_fh <= 0)
        return;
    std::vector<uint32_t> buf(size_t(g_fw) * g_fh, 0);
    g_convert(reinterpret_cast<uint8_t *>(buf.data()), g_fw * 4);
    if (g_cursor_on && g_overlay) g_overlay(reinterpret_cast<uint8_t *>(buf.data()), g_fw * 4);
    if (FILE *f = std::fopen(g_frame_out.c_str(), "wb")) {
        std::fprintf(f, "P6\n%d %d\n255\n", g_fw, g_fh);
        for (uint32_t p : buf) {
            std::fputc((p >> 16) & 0xFF, f); std::fputc((p >> 8) & 0xFF, f); std::fputc(p & 0xFF, f);
        }
        std::fclose(f);
    }
    std::fprintf(stderr, "frame: %d x %d after %llu instructions, written to %s\n", g_fw, g_fh,
                 (unsigned long long)g_icycles, g_frame_out.c_str());
    g_frame_done = true;
}

class Display::Impl {};

Display::Display() : impl(std::make_unique<Impl>()) {}
Display::~Display() {}
bool Display::configure(int w, int h) { g_fw = w; g_fh = h; return false; }
void Display::configure_dest() {}
void Display::configure_texture() {}
void Display::update_window_size() {}
void Display::blank() {}
void Display::update(std::function<void(uint8_t *, int)> convert, std::function<void(uint8_t *, int)> overlay,
                     bool cursor_on, int, int, bool) {
    g_convert = convert;
    g_overlay = overlay;
    g_cursor_on = cursor_on;
    frame_check();
}
void Display::update_skipped() { frame_check(); }
void Display::handle_events(const WindowEvent &) {}
void Display::setup_hw_cursor(std::function<void(uint8_t *, int)>, int, int) {}
void Display::update_window_title() {}
void Display::toggle_mouse_grab() {}
void Display::update_mouse_grab(bool) {}

/* ---- host events: none ever arrive ------------------------------------------ */

EventManager *EventManager::event_manager;

void EventManager::poll_events() {}
void EventManager::set_keyboard_locale(uint32_t keyboard_id) { this->kbd_locale = keyboard_id; }
void EventManager::post_keyboard_state_events() {}

/* ---- sound: plays nothing, but keeps the guest's output DMA moving ----------
   A real backend pulls the sound data on a timer. Without anything pulling,
   a DMA channel never reaches the end of its program and the ROM's startup
   chime would never finish, so drain it on a timer as the real one would. */

class SoundServer::Impl {
public:
    TimerInfo      drain_timer;
    DmaOutChannel *ch = nullptr;
};

SoundServer::SoundServer() : impl(std::make_unique<Impl>()) {
    supports_types(HWCompType::SND_SERVER);
}

SoundServer::~SoundServer() { close_out_stream(); }

int SoundServer::start() { return 0; }
void SoundServer::shutdown() { close_out_stream(); }

int SoundServer::open_out_stream(uint32_t, DmaOutChannel *dma_ch) {
    impl->ch = dma_ch;
    return 0;
}

int SoundServer::start_out_stream() {
    if (impl->drain_timer.active || !impl->ch)
        return 0;
    DmaOutChannel *ch = impl->ch;
    TimerManager::get_instance()->add_cyclic_timer(impl->drain_timer, MSECS_TO_NSECS(10),
        [ch](uint64_t, uint64_t) {
            if (!ch->is_out_active())
                return;
            uint8_t *chunk;
            uint32_t len;
            while (ch->pull_data(1024, &len, &chunk) == DmaPullResult::MoreData) {}
        });
    return 0;
}

void SoundServer::close_out_stream() {
    if (impl && impl->drain_timer.active) {
        TimerManager::get_instance()->cancel_timer(impl->drain_timer);
        impl->drain_timer.active = false;
    }
}
