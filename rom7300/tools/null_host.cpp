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
#include <functional>
#include <memory>

/* ---- globals the SDL files define ---------------------------------------- */

bool g_swap_command_option = false;   // core/hostevents_sdl.cpp
bool g_auto_grab_mouse     = false;   // devices/video/display_sdl.cpp

/* ---- display: accepts every call, shows nothing --------------------------- */

class Display::Impl {};

Display::Display() : impl(std::make_unique<Impl>()) {}
Display::~Display() {}
bool Display::configure(int, int) { return false; }
void Display::configure_dest() {}
void Display::configure_texture() {}
void Display::update_window_size() {}
void Display::blank() {}
void Display::update(std::function<void(uint8_t *, int)>, std::function<void(uint8_t *, int)>,
                     bool, int, int, bool) {}
void Display::update_skipped() {}
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
