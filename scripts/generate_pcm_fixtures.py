#!/usr/bin/env python3
"""Remux committed Hap samples with deterministic PCM; Python stdlib only.

Run from the repository root:
    python3 scripts/generate_pcm_fixtures.py
    python3 scripts/generate_pcm_fixtures.py --check

No encoder, FFmpeg, Apple framework, or third-party Python package is used.
The source video samples are copied byte-for-byte from hap1_audio.mov.
"""

import argparse
import math
from pathlib import Path
import struct


ROOT = Path(__file__).resolve().parent.parent
RATE = 48000
FRAMES = RATE * 2
CHUNK_FRAMES = 2048


def u16(value):
    return struct.pack(">H", value)


def u32(value):
    return struct.pack(">I", value)


def box(kind, payload):
    return u32(len(payload) + 8) + kind + payload


def fullbox(kind, payload, flags=0):
    return box(kind, u32(flags) + payload)


def boxes(data):
    """Walk bounded, ordinary-size boxes (the committed source needs no co64)."""
    offset = 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise ValueError("truncated box header")
        size, kind = struct.unpack_from(">I4s", data, offset)
        if size < 8 or size > len(data) - offset:
            raise ValueError("invalid box size")
        yield kind, data[offset + 8:offset + size]
        offset += size


def child(data, kind):
    return next(payload for name, payload in boxes(data) if name == kind)


def replace(data, replacements):
    return b"".join(box(kind, replacements.get(kind, payload))
                    for kind, payload in boxes(data))


def source_video(source):
    moov = child(source, b"moov")
    track = next(payload for kind, payload in boxes(moov)
                 if kind == b"trak" and
                 child(child(payload, b"mdia"), b"hdlr")[8:12] == b"vide")
    stbl = child(child(child(track, b"mdia"), b"minf"), b"stbl")
    stsz = child(stbl, b"stsz")
    size, count = struct.unpack_from(">II", stsz, 4)
    sizes = ([size] * count if size else
             list(struct.unpack_from(f">{count}I", stsz, 12)))
    stco = child(stbl, b"stco")
    chunk_count = struct.unpack_from(">I", stco, 4)[0]
    offsets = struct.unpack_from(f">{chunk_count}I", stco, 8)
    stsc = child(stbl, b"stsc")
    entry_count = struct.unpack_from(">I", stsc, 4)[0]
    entries = [struct.unpack_from(">III", stsc, 8 + i * 12)
               for i in range(entry_count)]
    samples = []
    entry = 0
    for chunk, offset in enumerate(offsets, 1):
        while entry + 1 < len(entries) and entries[entry + 1][0] <= chunk:
            entry += 1
        if entries[entry][2] != 1:
            raise ValueError("source changed sample description")
        for _ in range(entries[entry][1]):
            size = sizes[len(samples)]
            if offset + size > len(source):
                raise ValueError("source sample outside file")
            samples.append(source[offset:offset + size])
            offset += size
    if len(samples) != count or count != 60:
        raise ValueError("expected the committed 60-frame, two-second video")
    return child(source, b"ftyp"), child(moov, b"mvhd"), track, b"".join(samples)


def video_track(track, offset):
    mdia = child(track, b"mdia")
    minf = child(mdia, b"minf")
    stbl = replace(child(minf, b"stbl"), {
        b"stsc": u32(0) + u32(1) + u32(1) + u32(60) + u32(1),
        b"stco": u32(0) + u32(1) + u32(offset),
    })
    minf = replace(minf, {b"stbl": stbl})
    mdia = replace(mdia, {b"minf": minf})
    return box(b"trak", replace(track, {b"mdia": mdia}))


def pcm(bits):
    # Integer periodic lookup avoids accumulating oscillator phase error.
    table = [round(math.sin(2 * math.pi * i / 200) * ((1 << 23) - 1))
             for i in range(200)]
    result = bytearray()
    for frame in range(FRAMES):
        late = frame >= RATE
        # L/R have different frequencies AND swap 4:1 amplitude dominance at 1s.
        # Thus a stale seek/loop buffer cannot pass on constant-tone RMS alone.
        phases = (3, 6) if late else (2, 4)
        shifts = (3, 1) if late else (1, 3)
        edge = min(frame, FRAMES - 1 - frame, abs(frame - RATE))
        fade = min(edge, RATE // 100)
        for phase, shift in zip(phases, shifts):
            sample = (table[(frame * phase) % 200] >> shift) * fade // (RATE // 100)
            if bits == 16:
                sample >>= 8
            result.extend(sample.to_bytes(bits // 8, "big", signed=True))
    return bytes(result)


def audio_track(bits, offset):
    matrix = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)
    tkhd = fullbox(b"tkhd", b"\0" * 8 + u32(2) + u32(0) + u32(2000) +
                   b"\0" * 12 + u16(0x100) + u16(0) + matrix + b"\0" * 8, 3)
    mdhd = fullbox(b"mdhd", b"\0" * 8 + u32(RATE) + u32(FRAMES) +
                   u16(0x55C4) + u16(0))
    hdlr = fullbox(b"hdlr", u32(0) + b"soun" + b"\0" * 12 + b"PCM fixture\0")
    # Legacy in24 v1 uses nominal sampleSize=16/bytesPerSample=2, but its
    # actual packet/frame geometry is packed 24-bit (3/6 bytes), big endian.
    version = 1 if bits == 24 else 0
    entry = (b"\0" * 6 + u16(1) + u16(version) + u16(0) + u32(0) +
             u16(2) + u16(16) + u16(0) + u16(0) + u32(RATE << 16))
    if version == 1:
        entry += u32(1) + u32(3) + u32(6) + u32(2)
    stsd = fullbox(b"stsd", u32(1) + box(b"in24" if bits == 24 else b"twos", entry))
    chunks = list(range(0, FRAMES, CHUNK_FRAMES))
    counts = [min(CHUNK_FRAMES, FRAMES - frame) for frame in chunks]
    entries = [(i + 1, count, 1) for i, count in enumerate(counts)
               if i == 0 or counts[i - 1] != count]
    stsc = fullbox(b"stsc", u32(len(entries)) +
                   b"".join(struct.pack(">III", *entry) for entry in entries))
    stco = fullbox(b"stco", u32(len(chunks)) +
                   b"".join(u32(offset + frame * 2 * (bits // 8)) for frame in chunks))
    stbl = box(b"stbl", stsd + fullbox(b"stts", u32(1) + u32(FRAMES) + u32(1)) +
               stsc + fullbox(b"stsz", u32(2 * (bits // 8)) + u32(FRAMES)) + stco)
    dinf = box(b"dinf", fullbox(b"dref", u32(1) + fullbox(b"url ", b"", 1)))
    minf = box(b"minf", fullbox(b"smhd", b"\0" * 4) + dinf + stbl)
    return box(b"trak", tkhd + box(b"mdia", mdhd + hdlr + minf))


def generate(source, bits):
    ftyp, mvhd, track, video = source_video(source)
    ftyp = box(b"ftyp", ftyp)
    video_offset = len(ftyp) + 8
    return (ftyp + box(b"mdat", video + pcm(bits)) +
            box(b"moov", box(b"mvhd", mvhd) + video_track(track, video_offset) +
                audio_track(bits, video_offset + len(video))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify committed bytes without writing")
    args = parser.parse_args()
    source = (ROOT / "tests/fixtures/hap1_audio.mov").read_bytes()
    for bits in (16, 24):
        path = ROOT / f"tests/fixtures/hap1_pcm{bits}be_stereo.mov"
        data = generate(source, bits)
        if args.check:
            if path.read_bytes() != data:
                raise SystemExit(f"fixture differs: {path}")
            print(f"Verified {path.name} ({len(data)} bytes)")
        else:
            path.write_bytes(data)
            print(f"Generated {path.name} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
