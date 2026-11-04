#!/usr/bin/env python3
"""Deterministic game-file fixtures for the Cartouche Linux port smoke test.

Every byte is a pure function of its position, so the CRC32 of each file is stable
run-to-run and the test can assert on it. Sizes clear each platform's minimum so the
files read as games (the too-small and unsupported files deliberately do not).
"""
import os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/opt/data/cartouche-linux/roms"

def filler(n: int, seed: int) -> bytes:
    out = bytearray()
    for i in range(n):
        out.append(((i * 31 + seed * 17) & 0xFF))
    return bytes(out)

def w(path: str, data: bytes):
    full = os.path.join(ROOT, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb") as f:
        f.write(data)
    print(f"  {path}  ({len(data)} bytes)")

# --- NES cartridge, iNES header, 16 KB (>= 8192 min) -------------------------
def ines():
    h = bytearray()
    h += b"iNES"
    h += bytes([0, 1, 1, 0, 0, 0, 0, 0])   # ver, prg roms, chr roms, mapper, flags
    h += bytes([0, 0])                     # reserved
    return bytes(h) + filler(16384 - 16, 1)

# --- SNES cartridge, 68 KB (>= 65536 min) -------------------------------------
def snes():
    d = filler(69632, 2)
    return d

# --- PS2 CHD: >= 16 MB, CHD header at 0x80, serial embedded in first 8 MB ----
def ps2chd():
    n = 16500000
    d = bytearray(filler(n, 3))
    # CHD header at 0x80
    d[0x80:0x83] = b"CHD"
    d[0x83] = 1                      # format
    d[0x88:0x8C] = (4).to_bytes(4, "little")     # type
    d[0x90:0x94] = (16384).to_bytes(4, "little")  # sector count
    d[0x94:0x98] = (2048).to_bytes(4, "little")   # sector size
    d[0x98:0x9C] = (0xC0).to_bytes(4, "little")   # data start
    # Serial (matches the reference SLPM-66124) inside the first 8 MB.
    ser = "SLPM-66124".encode()
    d[0x1000:0x1000 + len(ser)] = ser
    return bytes(d)

# --- PSX ISO: 2 MB, CD001 + serial at the standard offsets -------------------
def psxiso():
    n = 2097152
    d = bytearray(filler(n, 4))
    d[0x8000:0x8005] = b"CD001"
    ser = "SCES-00867".encode()
    d[0x8005:0x8005 + len(ser)] = ser
    return bytes(d)

def main():
    print("fixtures ->", ROOT)
    w("Tetris (USA).nes", ines())
    w("too_small.nes", filler(100, 9))
    w("Super Mario World (USA).sfc", snes())
    w("Final Fantasy X (Japan).chd", ps2chd())
    w("Final Fantasy VII (Europe) (Disc 1).iso", psxiso())
    w("readme.txt", "not a game\n".encode())
    w(".git/config", "[core]\n".encode())
    print("done")

if __name__ == "__main__":
    main()
