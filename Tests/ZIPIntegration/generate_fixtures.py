"""Generate deterministic tiny archives with real ZIP32/ZIP64 record layouts.

Fixtures contain placeholder media bytes, not images. No huge disk allocation is needed to
exercise ZIP64 local headers, central-directory extended fields, EOCD64, and its locator.
"""
from pathlib import Path
import struct
import zlib


DESTINATION = Path(__file__).parent / "Tests/ZIPIntegrationTests/Fixtures"


def archive(entries, *, zip64=False, stored=False):
    local = bytearray()
    central = bytearray()
    payload_positions = []
    for name, payload in entries:
        name = name.encode("utf-8")
        crc = zlib.crc32(payload)
        if stored:
            compressed = payload
        else:
            compressor = zlib.compressobj(level=6, wbits=-15)
            compressed = compressor.compress(payload) + compressor.flush()
        offset = len(local)
        version = 45 if zip64 else 20
        method = 0 if stored else 8
        local_extra = struct.pack("<HHQQ", 1, 16, len(payload), len(compressed)) if zip64 else b""
        # A first local header at offset zero needs no 64-bit offset field. ZIPFoundation
        # 0.9.20 treats a ZIP64 offset value of zero as absent, so retain the ordinary zero
        # offset there; subsequent entries exercise its nonzero 64-bit offset decoding.
        if zip64 and offset:
            central_extra = struct.pack("<HHQQQ", 1, 24, len(payload), len(compressed), offset)
        elif zip64:
            central_extra = struct.pack("<HHQQ", 1, 16, len(payload), len(compressed))
        else:
            central_extra = b""
        packed = 0xFFFFFFFF if zip64 else len(compressed)
        unpacked = 0xFFFFFFFF if zip64 else len(payload)
        local += struct.pack("<IHHHHHIIIHH", 0x04034B50, version, 0, method, 0, 0x5021,
                             crc, packed, unpacked, len(name), len(local_extra))
        local += name + local_extra
        payload_positions.append(len(local))
        local += compressed
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, (3 << 8) | version,
                               version, 0, method, 0, 0x5021, crc, packed, unpacked,
                               len(name), len(central_extra), 0, 0, 0, 0o100644 << 16,
                               0xFFFFFFFF if zip64 and offset else offset)
        central += name + central_extra
    central_offset = len(local)
    result = local + central
    if zip64:
        zip64_offset = len(result)
        result += struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0,
                              len(entries), len(entries), len(central), central_offset)
        result += struct.pack("<IIQI", 0x07064B50, 0, zip64_offset, 1)
        result += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 0xFFFF, 0xFFFF,
                              0xFFFFFFFF, 0xFFFFFFFF, 0)
    else:
        result += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries),
                              len(central), central_offset, 0)
    return result, central_offset, payload_positions


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    normal, _, _ = archive([
        ("photos/", b""),
        ("photos/duplicate.jpg", b"first photo"),
        ("photos/duplicate.jpg", b"second photo"),
        (".DS_Store", b"finder metadata"),
        ("videos/clip.mov", b"small video payload"),
    ])
    (DESTINATION / "ordinary.zip").write_bytes(normal)
    zip64, _, _ = archive([
        ("photos/large-layout.jpg", b"ZIP64 photo payload"),
        ("videos/clip.mov", b"ZIP64 video payload"),
    ], zip64=True)
    (DESTINATION / "zip64.zip").write_bytes(zip64)
    stored, central_offset, payload_positions = archive([("photo.jpg", b"original photo payload")], stored=True)
    bad_crc = bytearray(stored)
    bad_crc[payload_positions[0]] ^= 0x01
    (DESTINATION / "bad-crc.zip").write_bytes(bad_crc)
    encrypted = bytearray(stored)
    struct.pack_into("<H", encrypted, 6, 1)
    struct.pack_into("<H", encrypted, central_offset + 8, 1)
    (DESTINATION / "encrypted-flag.zip").write_bytes(encrypted)
    multipart = bytearray(stored)
    struct.pack_into("<H", multipart, len(multipart) - 22 + 4, 1)
    (DESTINATION / "multipart.zip").write_bytes(multipart)
    (DESTINATION / "truncated.zip").write_bytes(stored[:-5])


if __name__ == "__main__":
    main()
