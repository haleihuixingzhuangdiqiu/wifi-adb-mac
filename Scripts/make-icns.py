#!/usr/bin/python3
"""Package PNG representations into a modern ICNS container, without iconutil services."""
import pathlib
import struct
import sys

folder = pathlib.Path(sys.argv[1])
representations = {
    b"icp4": "icon_16x16.png", b"icp5": "icon_32x32.png", b"icp6": "icon_32x32@2x.png",
    b"ic07": "icon_128x128.png", b"ic08": "icon_256x256.png", b"ic09": "icon_512x512.png",
    b"ic10": "icon_512x512@2x.png", b"ic11": "icon_16x16@2x.png", b"ic12": "icon_32x32@2x.png",
    b"ic13": "icon_128x128@2x.png", b"ic14": "icon_256x256@2x.png",
}
chunks = []
for kind, filename in representations.items():
    payload = (folder / filename).read_bytes()
    chunks.append(kind + struct.pack(">I", len(payload) + 8) + payload)
payload = b"".join(chunks)
pathlib.Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
