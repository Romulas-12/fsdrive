#!/usr/bin/env python3
"""Gives a Mach-O binary a fixed LC_UUID derived from a name.

macOS ties local network access to the binary's UUID and caches the UUID of a Finder
extension until the next restart, so every new build of FSDrive's extension lost
access to the NAS on the home network. With a fixed UUID each build is the same
binary to the system. Run before codesign (the signature covers the header).

The log system also finds a binary's message formats by UUID and keeps the first copy
it saw, so after a code change Console shows "<compose failure>" for FSDrive's own
messages. For debugging, build with FSDRIVE_NO_PIN=1.

usage: pin-uuid.py BINARY NAME
"""
import struct
import sys
import uuid

LC_UUID = 0x1B
MH_MAGIC_64 = 0xFEEDFACF

FAT_MAGIC = 0xCAFEBABE
CPU_TYPE_ARM64 = 0x0100000C


def pin(data, base, name):
    """Sets the LC_UUID of the thin Mach-O starting at `base` in `data`."""
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", data, base)
    if magic != MH_MAGIC_64:
        sys.exit(f"{path}: not a 64-bit Mach-O slice")
    offset = base + 32  # sizeof(mach_header_64)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == LC_UUID:
            data[offset + 8:offset + 24] = uuid.uuid5(uuid.NAMESPACE_DNS, name).bytes
            return
        offset += size
    sys.exit(f"{path}: no LC_UUID")


path, name = sys.argv[1], sys.argv[2]
data = bytearray(open(path, "rb").read())
if struct.unpack_from(">I", data, 0)[0] == FAT_MAGIC:
    # Universal binary (Xcode Release builds): every slice gets its own fixed UUID. The
    # arm64 one keeps the plain name, as the thin arm64 builds before had.
    (count,) = struct.unpack_from(">I", data, 4)
    for k in range(count):
        cputype, _, offset, _, _ = struct.unpack_from(">iiIII", data, 8 + 20 * k)
        pin(data, offset, name if cputype == CPU_TYPE_ARM64 else f"{name}.{cputype:x}")
else:
    pin(data, 0, name)
open(path, "wb").write(data)
