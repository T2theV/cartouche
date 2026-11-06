#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Builds the game files the Linux port's smoke test scans, in roms/.

- a NES and a SNES cartridge and a zipped NES ROM, whose ROM's CRC32 is one of
  the platform's printed No-Intro prints (so the launcher identifies them by
  content, like the cartridge prints do);
- a PS2 disc as a MAME v5 CHD (sixteen stored 1 MiB hunks, `lzma` named, the
  shape the core's own test fixtures write) and a PSX disc as a plain ISO 9660
  image, whose SYSTEM.CNF boots a serial the reference lists write;
- a file too small to be a game, and one no platform lists.

The formats are the core's ground truth (kotlin/core's files package): the
iNES header's sixteen bytes are not in the NES print, a copier's 512-byte
header is not in the SNES print (when the size tells of one), a zip's print is
the CRC its archive records, the PVD is sector sixteen with its root record
at 156 (extents and sizes little-endian, name length at 32, the name at 33,
as the core's fixtures write them), and the CHD is `MComprHD` version 5 with
its huffman map.

Run:  python3 make_fixtures.py   (writes roms/, verifies every fixture)
"""
import re
import struct
import sys
import zipfile
import zlib
from pathlib import Path

ROMS = Path(__file__).resolve().parent / "roms"

TETRIS = "Tetris (USA)"
TETRIS_PRINT = 0x1394F57E
SMB = "Super Mario Bros. (World)"
SMB_PRINT = 0x393A432F
SMW = "Super Mario World (USA)"
SMW_PRINT = 0xB19ED489
FFX = "Final Fantasy X (Japan)"
FFX_SERIAL = "SLPM_661.24"
FF7 = "Final Fantasy VII (Europe) (Disc 1)"
FF7_SERIAL = "SCES_008.67"

SECTOR = 2048
PVD_SECTOR = 16
ROOT_SECTOR = 17
CNF_SECTOR = 18
README_SECTOR = 19

CHD_HUNKS = 16
CHD_HUNK_SIZE = 1 << 20
CHD_IMAGE_SIZE = CHD_HUNKS * CHD_HUNK_SIZE

BOOT_RE = re.compile(r"BOOT2?\s*=\s*cdrom0?:\\?\\?([A-Z]{4}[_-]\d{3}\.\d{2})")


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def solve_suffix(prefix: bytes, target: int) -> bytes:
    """The four bytes S such that crc32(prefix + S) == target.

    The CRC is linear: crc32(prefix+S) = crc32(prefix+0^4) ^ crc32(0^len+S), so
    the suffix solves a 32x32 linear system over GF(2); its kernel is trivial
    (no 32-bit value is a multiple of the generator), so a unique solution
    always exists.
    """
    m = len(prefix)
    base = crc32(b"\0" * (m + 4))
    aug = crc32(prefix + b"\0" * 4) ^ target
    cols = []
    for j in range(32):
        e = bytearray(4)
        e[j // 8] = 1 << (j % 8)
        # the CRC is affine: the linear part is the full CRC minus crc(0^len)
        cols.append(crc32(b"\0" * m + bytes(e)) ^ base)
    rows = []
    for i in range(32):
        mask = 0
        for j in range(32):
            if (cols[j] >> i) & 1:
                mask |= 1 << j
        rows.append([mask, (aug >> i) & 1])
    pivot_row = {}
    top = 0
    for col in range(32):
        pivot = next((i for i in range(top, 32) if rows[i][0] & (1 << col)), None)
        if pivot is None:
            continue
        rows[top], rows[pivot] = rows[pivot], rows[top]
        for i in range(32):
            if i != top and rows[i][0] & (1 << col):
                rows[i] = [rows[i][0] ^ rows[top][0], rows[i][1] ^ rows[top][1]]
        pivot_row[col] = top
        top += 1
    if len(pivot_row) != 32:
        raise RuntimeError("rank-deficient: no unique four-byte suffix")
    value = 0
    for col, row in pivot_row.items():
        if rows[row][0] != (1 << col):
            raise RuntimeError("elimination left a non-pivot row")
        if rows[row][1]:
            value |= 1 << col
    suffix = bytearray(4)
    for j in range(32):
        if (value >> j) & 1:
            suffix[j // 8] |= 1 << (j % 8)
    if crc32(prefix + bytes(suffix)) != target:
        raise RuntimeError("suffix solver failed its own check")
    return bytes(suffix)


def rom_with_crc(size: int, target: int, hashed_from: int = 0, header: bytes = b"") -> bytes:
    """A [size]-byte file whose bytes from hashed_on reach the target CRC32."""
    assert len(header) <= hashed_from <= size - 4
    head_len = size - hashed_from - 4
    out = bytearray(size)
    out[0:len(header)] = header
    out[hashed_from:size - 4] = bytes((i * 7 + 13) & 0xFF for i in range(head_len))
    out[size - 4:] = solve_suffix(bytes(out[hashed_from:size - 4]), target)
    assert crc32(bytes(out[hashed_from:])) == target
    return bytes(out)


def ines_header() -> bytes:
    """The 16-byte iNES header of a 32 KiB PRG cartridge."""
    return "NES\x1a".encode() + bytes([1, 1, 0x01, 0x40]) + "CARTOUCH".encode()


def iso9660(serial: str, ps2: bool) -> bytes:
    """A 32-sector ISO 9660 image: the PVD at 16, the root directory at 17
    (little-endian extents and sizes, the name length at 32 and the name at
    33, as the core's fixtures write them), and SYSTEM.CNF at 18 booting
    [serial]."""
    boot = f"BOOT{'2' if ps2 else ''} = cdrom{'0' if ps2 else ''}:\\{serial};1\r\nVER = 1.00\r\nVMODE = PAL\r\n".encode()
    image = bytearray(SECTOR * 32)

    # -- the primary volume descriptor --------------------------------------
    pvd = bytearray(SECTOR)
    pvd[0] = 1
    pvd[1:6] = "CD001".encode()
    pvd[6] = 1
    pvd[128:128 + 32] = "CARTOUCHE".ljust(32).encode()
    root = 156
    pvd[root] = 34  # the record length
    pvd[root + 1] = 0
    struct.pack_into("<I", pvd, root + 2, ROOT_SECTOR)
    struct.pack_into("<I", pvd, root + 6, SECTOR)
    struct.pack_into("<I", pvd, root + 10, SECTOR)
    pvd[root + 32] = 0  # the name length: none
    image[PVD_SECTOR * SECTOR:(PVD_SECTOR + 1) * SECTOR] = pvd

    # -- the root directory --------------------------------------------------
    root_dir = bytearray(SECTOR)

    def record(at: int, name: str, extent: int, size: int) -> None:
        root_dir[at] = 33 + len(name)
        struct.pack_into("<I", root_dir, at + 2, extent)
        struct.pack_into("<I", root_dir, at + 6, size)
        struct.pack_into("<I", root_dir, at + 10, size)
        root_dir[at + 32] = len(name)
        root_dir[at + 33:at + 33 + len(name)] = name.encode()

    record(0, "SYSTEM.CNF;1", CNF_SECTOR, len(boot))
    record(33 + 12, "README.TXT;1", README_SECTOR, 4)
    image[ROOT_SECTOR * SECTOR:(ROOT_SECTOR + 1) * SECTOR] = root_dir

    # -- the files -----------------------------------------------------------
    image[CNF_SECTOR * SECTOR:CNF_SECTOR * SECTOR + len(boot)] = boot
    image[README_SECTOR * SECTOR:README_SECTOR * SECTOR + 7] = "A disc.".encode()
    return bytes(image)


def chd(image: bytes) -> bytes:
    """The MAME v5 CHD of [image]: header, huffman map, the stored hunks.

    The map mirrors the core's own test fixture: sixteen 4-bit lengths, the
    kinds run-length coded (one stored hunk, a RLE_SMALL, a count), then a
    16-bit checksum per stored hunk; the first hunk sits after the map.
    """
    assert len(image) == CHD_IMAGE_SIZE
    bits = []

    def put(value: int, count: int) -> None:
        for i in range(count - 1, -1, -1):
            bits.append((value >> i) & 1)

    for _ in range(16):  # the tree: sixteen codes, four bits each
        put(4, 4)
    put(4, 4)  # the first hunk, stored
    put(7, 4)  # RLE_SMALL
    put(12, 4)  # twelve more repeat it
    for _ in range(CHD_HUNKS):  # the entries: a 16-bit checksum per hunk
        put(0, 16)
    while len(bits) % 8:
        bits.append(0)
    body = bytes(
        int("".join(str(bit) for bit in bits[i * 8:(i + 1) * 8]), 2)
        for i in range(len(bits) // 8)
    )
    first_hunk = 124 + 16 + len(body)

    header = bytearray()
    header += "MComprHD".encode()  # 0..8
    header += struct.pack(">I", 124)  # 8..12
    header += struct.pack(">I", 5)  # 12..16
    header += "lzma".encode() * 4  # 16..32
    header += struct.pack(">Q", CHD_IMAGE_SIZE)  # 32..40
    header += struct.pack(">Q", 124)  # 40..48
    header += struct.pack(">Q", 0)  # 48..56, no metadata: a DVD
    header += struct.pack(">I", CHD_HUNK_SIZE)  # 56..60
    header += struct.pack(">I", CHD_HUNK_SIZE)  # 60..64
    header += bytes(60)  # 64..124
    assert len(header) == 124

    head = bytearray()
    head += struct.pack(">I", len(body))
    head += int.to_bytes(first_hunk, 6, "big")
    head += bytes([0, 0, 20, 10, 10, 0])  # length, self, parent bits, then 0
    return bytes(header + head + body + image)


# --- the verifier: the same reading the launcher does ------------------------


def chd_read(file: bytes) -> dict:
    """The MAME v5 CHD reading, mirroring the launcher's (and the core's)."""
    assert file[:8] == "MComprHD".encode()
    version = struct.unpack(">I", file[12:16])[0]
    assert version == 5, version
    logical = struct.unpack(">Q", file[32:40])[0]
    hunk_size = struct.unpack(">I", file[56:60])[0]
    hunks = logical // hunk_size
    head = file[124:140]
    body_len = struct.unpack(">I", head[:4])[0]
    first_hunk = int.from_bytes(head[4:10], "big")
    length_bits, self_bits, parent_bits = head[12], head[13], head[14]
    body = file[140:140 + body_len]

    class Reader:
        """Bits, most significant first, zeros past the end."""

        def __init__(self, data: bytes):
            self.data = data
            self.position = 0

        def read(self, count: int) -> int:
            value = 0
            left = count
            while left > 0:
                index = self.position >> 3
                byte = self.data[index] if index < len(self.data) else 0
                taken = min(8 - (self.position & 7), left)
                value = (value << taken) | (byte >> (8 - (self.position & 7) - taken)) & ((1 << taken) - 1)
                self.position += taken
                left -= taken
            return value

        def huff(self, symbols: list) -> int:
            code = 1
            for _ in range(8):
                code = (code << 1) | self.read(1)
                if code < len(symbols) and symbols[code] >= 0:
                    return symbols[code]
            return -1

    reader = Reader(body)

    # -- the huffman tree -----------------------------------------------------
    lengths = [0] * 16
    node = 0
    while node < 16:
        length = reader.read(4)
        if length != 1:
            lengths[node] = length
            node += 1
            continue
        repeated = reader.read(4)
        count = 1 if repeated == 1 else reader.read(4) + 3
        for _ in range(count):
            lengths[node] = repeated
            node += 1
    starts = [0] * 33
    for length in lengths:
        starts[length] += 1
    start = 0
    for length in range(32, 0, -1):
        nxt = (start + starts[length]) >> 1
        starts[length] = start
        start = nxt
    symbols = [-1] * 512
    for symbol, length in enumerate(lengths):
        if 1 <= length <= 8 and starts[length] < (1 << length):
            symbols[(1 << length) | starts[length]] = symbol
            starts[length] += 1

    # -- the kinds, run-length coded ------------------------------------------
    kinds = [0] * hunks
    last = 0
    repeat = 0
    for hunk in range(hunks):
        if repeat > 0:
            kinds[hunk] = last
            repeat -= 1
            continue
        code = reader.huff(symbols)
        if code in (7, 8):
            kinds[hunk] = last
            count = reader.huff(symbols)
            if code == 7:
                repeat = 2 + count
            else:
                repeat = 2 + 16 + (count << 4) + reader.huff(symbols)
        else:
            kinds[hunk] = code
            last = code
    entries_at = reader.position

    # -- the walk: where each hunk's bytes sit ---------------------------------
    stored: dict = {}
    offset = first_hunk
    last_self = 0
    self_of = [0] * hunks
    for hunk in range(hunks):
        kind = kinds[hunk]
        start = offset
        if kind in (0, 1, 2, 3):
            value_len = reader.read(length_bits)
            reader.read(16)
            offset += value_len
        elif kind == 4:
            reader.read(16)
            offset += hunk_size
        elif kind == 5:
            last_self = reader.read(self_bits)
        elif kind == 10:
            last_self += 1
        elif kind == 6:
            reader.read(parent_bits)
        # kind 9 (SELF_0) reads nothing
        self_of[hunk] = last_self
        stored[hunk] = (start, kind)
    assert entries_at <= reader.position
    assert len(file) == first_hunk + hunks * hunk_size

    per_hunk = hunk_size // SECTOR

    def sector(n: int) -> bytes:
        hunk = n // per_hunk
        offset_in = (n % per_hunk) * SECTOR
        start, kind = stored[hunk]
        if kind in (0, 1, 2, 3):
            return bytes(SECTOR)
        if kind in (5, 9, 10):
            target = self_of[hunk]
            start, kind = stored[target]
            if kind in (0, 1, 2, 3):
                return bytes(SECTOR)
        data = file[start:start + hunk_size]
        return data[offset_in:offset_in + SECTOR]

    return {"sector": sector, "kinds": kinds, "self_of": self_of, "entries_at": entries_at}


def read_serial(image: bytes) -> str | None:
    """The boot serial of an ISO 9660 image, mirroring the launcher's."""
    pvd = image[PVD_SECTOR * SECTOR:(PVD_SECTOR + 1) * SECTOR]
    if pvd[1:6] != "CD001".encode():
        return None
    root_sector = struct.unpack_from("<I", pvd, 156 + 2)[0]
    root_size = struct.unpack_from("<I", pvd, 156 + 10)[0]
    directory = image[root_sector * SECTOR:root_sector * SECTOR + root_size]
    at = 0
    while at < len(directory):
        length = directory[at]
        if length == 0:
            at = (at // SECTOR + 1) * SECTOR
            continue
        if at + 33 >= len(directory):
            break
        name_len = directory[at + 32]
        if at + 33 + name_len > len(directory):
            break
        name = directory[at + 33:at + 33 + name_len].decode("latin-1").upper()
        name = name.split(";")[0]
        extent = struct.unpack_from("<I", directory, at + 2)[0]
        size = struct.unpack_from("<I", directory, at + 10)[0]
        if name == "SYSTEM.CNF":
            cnf = image[extent * SECTOR:extent * SECTOR + size]
            match = BOOT_RE.search(cnf.decode("latin-1"))
            return match.group(1) if match else None
        at += length
    return None


def verify() -> bool:
    ok = True

    def check(label: str, condition: bool) -> None:
        nonlocal ok
        print(f"  {'ok ' if condition else 'FAIL'} {label}")
        ok = ok and condition

    tetris = (ROMS / f"{TETRIS}.nes").read_bytes()
    check("tetris iNES magic", tetris[:4] == "NES\x1a".encode())
    check("tetris ROM print", crc32(tetris[16:]) == TETRIS_PRINT)

    with zipfile.ZipFile(ROMS / f"{SMB}.zip") as archive:
        info = archive.infolist()[0]
        entry = archive.read(info.filename)
        check("zip single stored entry", len(archive.infolist()) == 1 and info.compress_type == zipfile.ZIP_STORED)
        check("zip entry size", len(entry) == 8192)
        check("zip recorded print", info.CRC == SMB_PRINT and crc32(entry) == SMB_PRINT)

    smw = (ROMS / f"{SMW}.sfc").read_bytes()
    check("smw size", len(smw) == 66048 and len(smw) % 1024 == 512)
    check("smw SMC magic", smw[:4] == bytes([0x7C, 0x10, 0x13, 0x12]))
    check("smw ROM print", crc32(smw[512:]) == SMW_PRINT)

    iso_ff7 = (ROMS / f"{FF7}.iso").read_bytes()
    check("ff7 iso CD001", iso_ff7[0x8001:0x8006] == "CD001".encode())
    check("ff7 boot serial", read_serial(iso_ff7) == FF7_SERIAL)

    chd_bytes = (ROMS / f"{FFX}.chd").read_bytes()
    check("ffx chd size", len(chd_bytes) == 124 + 16 + 42 + CHD_IMAGE_SIZE)
    info = chd_read(chd_bytes)
    check("ffx chd kinds stored", set(info["kinds"]) == {4})
    image = bytearray(CHD_IMAGE_SIZE)
    for n in range(32):
        image[n * SECTOR:(n + 1) * SECTOR] = info["sector"](n)
    check("ffx chd serial", read_serial(bytes(image)) == FFX_SERIAL)
    return ok


def main() -> int:
    ROMS.mkdir(exist_ok=True)

    # -- the cartridges ------------------------------------------------------
    tetris_rom = rom_with_crc(8192, TETRIS_PRINT, hashed_from=16, header=ines_header())
    (ROMS / f"{TETRIS}.nes").write_bytes(tetris_rom)

    smb_rom = rom_with_crc(8192, SMB_PRINT)
    zip_path = ROMS / f"{SMB}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_STORED) as archive:
        archive.writestr(f"{SMB}.nes", smb_rom)

    smw_header = bytes([0x7C, 0x10, 0x13, 0x12]) + bytes([0x5C] * (512 - 4))
    smw = rom_with_crc(66048, SMW_PRINT, hashed_from=512, header=smw_header)
    (ROMS / f"{SMW}.sfc").write_bytes(smw)

    # -- the discs -----------------------------------------------------------
    (ROMS / f"{FFX}.chd").write_bytes(chd(iso9660(FFX_SERIAL, ps2=True).ljust(CHD_IMAGE_SIZE, b"\0")))
    (ROMS / f"{FF7}.iso").write_bytes(iso9660(FF7_SERIAL, ps2=False))

    # -- the not-games -------------------------------------------------------
    (ROMS / "too_small.nes").write_bytes(bytes(100))
    (ROMS / "readme.txt").write_text("Cartouche (Linux) fixtures: the files this test scans.\n")

    for path in sorted(ROMS.iterdir(), key=lambda p: p.name):
        if path.is_file():
            print(f"  {path.name}\t{path.stat().st_size}")
    print("verifying...")
    return 0 if verify() else 1


if __name__ == "__main__":
    sys.exit(main())
