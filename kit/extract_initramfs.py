#!/usr/bin/env python3
"""Pull the stock initramfs (newc cpio) out of an official firmware image.

    python3 extract_initramfs.py <input> <output.cpio>

<input> may be any of:

  * boot.img / kernel.img   HiSilicon ADVCA image.  The initramfs is a gzip
                            member inside it whose payload is a newc cpio
                            ("070701...").  This replaces `binwalk -e`.
  * an update zip           the decrypted official update package; boot.img
                            is read from inside it.
  * a cpio                  already extracted (e.g. binwalk's 988000 / 98E000);
                            copied as is.

Exits non-zero if no initramfs is found.  Images that are already USB-boot
initramfs (.uimg) are not handled here; build_kit.sh repacks those directly.
"""

import sys
import zipfile
import zlib

CPIO_MAGIC = b"070701"
GZIP_MAGIC = b"\x1f\x8b\x08"


def read_input(path):
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            names = [n for n in z.namelist() if n.rsplit("/", 1)[-1] in ("boot.img", "kernel.img")]
            if not names:
                sys.exit(f"[!] {path}: no boot.img / kernel.img inside the zip")
            print(f"[*] using {names[0]} from {path}")
            return z.read(names[0])
    with open(path, "rb") as f:
        return f.read()


def find_initramfs(data):
    if data.startswith(CPIO_MAGIC):
        return data
    i = 0
    while True:
        i = data.find(GZIP_MAGIC, i)
        if i < 0:
            return None
        try:
            out = zlib.decompressobj(31).decompress(data[i:])
        except zlib.error:
            out = b""
        if out.startswith(CPIO_MAGIC) and b"TRAILER!!!" in out:
            print(f"[+] initramfs: gzip at 0x{i:x}, {len(out)} bytes of cpio")
            return out
        i += len(GZIP_MAGIC)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    data = read_input(src)
    cpio = find_initramfs(data)
    if cpio is None:
        sys.exit(f"[!] {src}: no initramfs (gzip'd newc cpio) found")
    with open(dst, "wb") as f:
        f.write(cpio)


if __name__ == "__main__":
    main()
