#!/usr/bin/env python3
"""The codec's output as the board played it, from the trace's sound records
(kind 13: a SND_TRACE = 1, TRACE = 1 build; seven frames a record), as a WAV,
and compared with the ROM's chime bytes.

    python syn\\sndtrace.py CAPTURE.bin OUT.wav [--rate HZ] [--rom releases/boot0.rom]

The capture is mister.py trace-capture / trace-fetch's. Prints the frame
count, the gaps (records lost), how many frames are held (equal to the one
before) and, with --rom, where the played frames first differ from the
ROM's chime data (the DMA command list at FFE00020).
"""
import struct
import sys
import wave


def main():
    a = sys.argv[1:]
    cap, out = a[0], a[1]
    rate = int(a[a.index("--rate") + 1]) if "--rate" in a else 22050
    rom = a[a.index("--rom") + 1] if "--rom" in a else None
    raw = open(cap, "rb").read()
    frames, last_cnt, gaps = [], None, 0
    for k in range(0, len(raw) - 35, 36):
        r = raw[k + 4:k + 36]
        if r[0] != 13:
            continue
        cnt = int.from_bytes(r[1:4], "little")
        if last_cnt is not None and cnt != last_cnt + 7:
            gaps += 1
            frames.extend([(0, 0)] * max(0, min(cnt - last_cnt - 7, 7000)))   # lost records as silence
        last_cnt = cnt
        for j in range(28, 0, -4):
            l = int.from_bytes(r[j:j + 2], "little", signed=True)
            rr = int.from_bytes(r[j + 2:j + 4], "little", signed=True)
            frames.append((l, rr))
    if not frames:
        print("no sound records in the capture (a SND_TRACE = 1 build writes kind 13)")
        return 1
    held = sum(1 for k in range(1, len(frames)) if frames[k] == frames[k - 1])
    print("%d frames (%.2f s at %d Hz), %d gaps, %d held frames" % (len(frames), len(frames) / rate, rate, gaps, held))
    w = wave.open(out, "wb")
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(b"".join(struct.pack("<hh", l, r) for l, r in frames))
    w.close()
    if rom:
        data = open(rom, "rb").read()
        base = 0xFFC00000
        chime = b""
        for addr in range(0xFFE00020, 0xFFE00090, 16):
            c = data[addr - base:addr - base + 16]
            req = c[0] | (c[1] << 8)
            src = int.from_bytes(c[4:8], "little")
            chime += data[src - base:src - base + req]
        ref = [(struct.unpack(">h", chime[k:k + 2])[0], struct.unpack(">h", chime[k + 2:k + 4])[0])
               for k in range(0, len(chime), 4)]
        # align: the first played frame that equals the chime's first frame
        start = next((k for k in range(len(frames)) if frames[k] == ref[0] and frames[k + 1:k + 4] == ref[1:4]), None)
        if start is None:
            print("the chime's first frames were not found in the capture")
            return 0
        n = min(len(ref), len(frames) - start)
        bad = [k for k in range(n) if frames[start + k] != ref[k]]
        print("chime found at frame %d; %d of %d frames compared, %d differ" % (start, n, len(ref), len(bad)))
        for k in bad[:20]:
            print("  frame %6d: played %6d/%6d, ROM %6d/%6d" % (k, frames[start + k][0], frames[start + k][1], ref[k][0], ref[k][1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
