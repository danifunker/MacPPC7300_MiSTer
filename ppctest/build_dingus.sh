#!/bin/bash
# Build a private, sound-less, headless copy of the user's dingusppc checkout
# under WSL. Nothing is downloaded and the checkout itself is not touched.
set -e
SRC=/mnt/c/Temp/mistercore/dingusppc
DST=$HOME/.cache/ppcmac/dingusppc-src
BLD=$HOME/.cache/ppcmac/dingusppc-build
mkdir -p "$DST" "$BLD"
rsync -a --delete --exclude .git --exclude build "$SRC/" "$DST/" 2>/dev/null || { rm -rf "$DST"; mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/; rm -rf "$DST/.git"; }
cd "$DST"
# no cubeb: a sound server that plays nothing but keeps the guest's DMA moving
rm -f devices/sound/soundserver_cubeb.cpp
cat > devices/sound/soundserver_null.cpp <<'CPP'
// No host audio: drain the guest's sound DMA on a timer, as the real backend
// does in deterministic mode, so the ROM's startup chime can finish.
#include <core/timermanager.h>
#include <devices/common/dmacore.h>
#include <devices/sound/soundserver.h>

class SoundServer::Impl {
public:
    TimerInfo poll_timer;
    timer_cb  poll_cb;
};

SoundServer::SoundServer() : impl(std::make_unique<Impl>()) {
    supports_types(HWCompType::SND_SERVER);
}
SoundServer::~SoundServer() {}
int SoundServer::start() { return 0; }
void SoundServer::shutdown() {}
int SoundServer::open_out_stream(uint32_t, DmaOutChannel *dma_ch) {
    impl->poll_cb = [dma_ch](uint64_t, uint64_t) {
        if (!dma_ch->is_out_active())
            return;
        while (1) {
            uint8_t *chunk;
            uint32_t chunk_size;
            if (DmaPullResult::MoreData != dma_ch->pull_data(1024, &chunk_size, &chunk))
                break;
        }
    };
    return 0;
}
int SoundServer::start_out_stream() {
    if (!impl->poll_timer.active)
        TimerManager::get_instance()->add_cyclic_timer(
            impl->poll_timer, MSECS_TO_NSECS(10), impl->poll_cb);
    return 0;
}
void SoundServer::close_out_stream() {
    if (impl->poll_timer.active) {
        TimerManager::get_instance()->cancel_timer(impl->poll_timer);
        impl->poll_timer.active = 0;
    }
}
CPP
sed -i 's/add_subdirectory(thirdparty\/cubeb EXCLUDE_FROM_ALL)/# cubeb left out/' CMakeLists.txt
sed -i 's/SDL2::SDL2 cubeb/SDL2::SDL2/g; s/PRIVATE cubeb SDL2::SDL2/PRIVATE SDL2::SDL2/g' CMakeLists.txt devices/CMakeLists.txt
# headless: a plain window and the software renderer work with SDL_VIDEODRIVER=dummy
sed -i 's/SDL_WINDOW_OPENGL | SDL_WINDOW_ALLOW_HIGHDPI/0/; s/SDL_RENDERER_ACCELERATED/SDL_RENDERER_SOFTWARE/' devices/video/display_sdl.cpp
cd "$BLD"
cmake -DCMAKE_BUILD_TYPE=Release "$DST" > cmake.log 2>&1 || { tail -30 cmake.log; exit 1; }
make -j"$(nproc)" dingusppc > make.log 2>&1 || { grep -n "error" make.log | head -30; tail -15 make.log; exit 1; }
ls -la bin/
