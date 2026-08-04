#!/usr/bin/env python3
"""Generate synthetic TLV null-packet streams to exercise dantto4k's demuxer.

TLV packet layout (ARIB STD-B32): 0x7F | packetType | dataLength(BE16) | data
NullPacket = 0xFF. dantto4k counts these in statistics.tlvNullPacketCount,
which it prints to stderr, so the count is an end-to-end assertion that the
stream actually flowed through the demuxer.
"""
import sys

PAYLOAD = 16


def packet() -> bytes:
    return b"\x7f\xff" + PAYLOAD.to_bytes(2, "big") + b"\x00" * PAYLOAD


def main() -> None:
    count = int(sys.argv[1])
    out = sys.argv[2]
    with open(out, "wb") as f:
        f.write(packet() * count)
    print(f"{out}: {count} null packets, {count * (4 + PAYLOAD)} bytes")


if __name__ == "__main__":
    main()
