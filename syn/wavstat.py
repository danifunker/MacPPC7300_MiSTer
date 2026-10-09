#!/usr/bin/env python3
"""What a WAV of the core's sound holds (run_machine.py --wav, or a capture):
per 100 ms block the peak and RMS level in dBFS, and the frames held (a frame
equal to the one before it, beyond the holds a lower sample rate makes),
which is what an underrun sounds like.

    python syn\\wavstat.py FILE.wav [--hold N]   N: the holds a frame normally has (1 at 22,050 Hz in a 44,100 Hz file)
"""
import math
import struct
import sys
import wave


def main():
    a = sys.argv[1:]
    hold_n = int(a[a.index("--hold") + 1]) if "--hold" in a else 1
    w = wave.open(a[0], "rb")
    ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(n)
    frames = struct.unpack("<%dh" % (n * ch), raw)
    print("%s: %d channels, %d bits, %d Hz, %d frames (%.2f s)" % (a[0], ch, 8 * width, rate, n, n / rate))
    block = rate // 10
    first_sound = None
    for b in range(0, n, block):
        seg = frames[b * ch:(b + block) * ch]
        if not seg:
            break
        peak = max(abs(s) for s in seg)
        rms = math.sqrt(sum(s * s for s in seg) / len(seg))
        # runs of identical consecutive frames longer than the rate's own holds
        held, run = 0, 0
        for k in range(ch, len(seg), ch):
            if seg[k:k + ch] == seg[k - ch:k]:
                run += 1
                if run > hold_n:
                    held += 1
            else:
                run = 0
        if peak > 0 and first_sound is None:
            first_sound = b / rate
        if peak > 0:
            print("%6.1f s  peak %6d (%6.1f dBFS)  rms %6.1f dBFS  held frames %5d of %d"
                  % (b / rate, peak, 20 * math.log10(peak / 32768.0), 20 * math.log10(max(rms, 1) / 32768.0),
                     held, len(seg) // ch))
    allpeak = max(abs(s) for s in frames) if frames else 0
    print("first sound at %s; whole file peak %d (%.1f dBFS)"
          % ("%.2f s" % first_sound if first_sound is not None else "never", allpeak,
             20 * math.log10(allpeak / 32768.0) if allpeak else -999))


if __name__ == "__main__":
    sys.exit(main())
