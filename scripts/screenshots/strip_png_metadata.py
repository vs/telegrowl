#!/usr/bin/env python3
"""Remove metadata chunks (EXIF, text, ICC profiles, C2PA manifests) from PNG files in place.

Usage: strip_png_metadata.py FILE.png [FILE.png ...]
"""
import struct
import sys

# Chunks needed to render the image; everything else is dropped.
KEEP = {b"IHDR", b"PLTE", b"tRNS", b"sRGB", b"gAMA", b"IDAT", b"IEND"}


def strip(file_path: str) -> None:
    with open(file_path, "rb") as f:
        data = f.read()

    out = bytearray(data[:8])  # PNG signature
    offset = 8
    while offset < len(data):
        length, chunk_type = struct.unpack(">I4s", data[offset:offset + 8])
        end = offset + 12 + length  # length + type + data + CRC
        if chunk_type in KEEP:
            out += data[offset:end]
        offset = end

    with open(file_path, "wb") as f:
        f.write(out)


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        strip(arg)
