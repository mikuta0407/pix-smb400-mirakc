#!/usr/bin/env python3
"""
PIX-SMB400 / TU-BUHD100 USB Boot Bootargs Injection Tool
Creates root_rsa_pub_crc.bin and bootargs.bin for USB boot pin bypass

Device variants
---------------
The Hi3798CV200 board is sold under several brands and the Ethernet PHY is not
wired the same way on all of them.  `phy_addr` must match the board or the
device boots without networking (and therefore without ADB over TCP).

    SMB400      phy_addr=2,1   PIX-SMB400 / Panasonic POE-SMB400-PS1
    TU-BUHD100  phy_addr=2,3   Panasonic TU-BUHD100
                               (per https://github.com/SomeDena786/Uboot-TU-BUHD100)

Select with either:

    python3 make_usb_boot.py --variant TU-BUHD100
    VARIANT=TU-BUHD100 python3 make_usb_boot.py

Default is SMB400.  Everything else (RSA key handling, CRC layout) is identical
between the variants.

bootargs.bin format (raw u-boot env block):
  [0:4]    = CRC32 of remaining data (little-endian)
  [4:...]  = key=value\\0 pairs
  [...]    = \\0 (terminator)
  [...:N]  = zero-padded to block size

root_rsa_pub_crc.bin format:
  [0:256]   = RSA modulus (big-endian)
  [256:260] = RSA exponent (little-endian, e=3)
  [260:264] = CRC32 of [0:260] (little-endian)
"""

import re
import struct
import hashlib
import binascii
import os
import sys

from Crypto.PublicKey import RSA
from Crypto.Signature import pkcs1_15
from Crypto.Hash import SHA256

BOOTARGS_TOTAL_SIZE = 65536  # 64KB (matches bootargs partition size)

# Board-specific Ethernet PHY address.  See the module docstring.
PHY_ADDR_BY_VARIANT = {
    "SMB400":     "2,1",
    "TU-BUHD100": "2,3",
}


def resolve_variant(argv=None):
    """Pick the board variant from --variant / $VARIANT, defaulting to SMB400."""
    argv = sys.argv[1:] if argv is None else argv
    variant = os.environ.get("VARIANT", "SMB400")
    for i, a in enumerate(argv):
        if a == "--variant" and i + 1 < len(argv):
            variant = argv[i + 1]
        elif a.startswith("--variant="):
            variant = a.split("=", 1)[1]
    if variant not in PHY_ADDR_BY_VARIANT:
        sys.exit(
            f"[!] unknown variant {variant!r}; "
            f"choose one of {', '.join(sorted(PHY_ADDR_BY_VARIANT))}"
        )
    return variant


# Bootargs payload content (u-boot env format)
# Modified: selinux=permissive, keep everything else the same
BOOTARGS_ENV = """bootdelay=0
verify=n
baudrate=115200
ipaddr=192.168.1.10
serverip=192.168.1.1
netmask=255.255.255.0
bootfile=uImage
phy_intf=mii,rgmii
use_mdio=0,1
phy_addr=2,1
gmac_debug=0
bootcmd=mmc read 0 0x7D400000 0x6E000 0x4000;bootm 0x7D400000;mmc read 0 0x1FFBFC0 0x50000 0xC800;fatload usb 0:1 0x05000000 initramfs_patched.uimg;bootm 0x02001FC0 0x05000000
bootargs=enforcing=0 androidboot.selinux=permissive androidboot.serialno=0123456789 androidboot.optimize=true console=ttyAMA0,115200 loglevel=8 blkdevparts=mmcblk0:1M(fastboot),1M(bootargs),20M(recovery),2M(deviceinfo),8M(baseparam),8M(pqparam),20M(logo),20M(logobak),40M(fastplay),40M(fastplaybak),40M(kernel),20M(misc),40M(trustedcore),1136M(system),400M(vendor),824M(cache),50M(private),8M(securestore),100M(customer),-(userdata) hbcomp=/dev/block/mmcblk0p14
bootargs_512M=mem=512M mmz=ddr,0,0,32M vmalloc=500M
bootargs_768M=mem=768M mmz=ddr,0,0,32M vmalloc=500M
bootargs_1G=mem=969M mmz=ddr,0,0,56M vmalloc=500M
bootargs_2G=mem=1961M mmz=ddr,0,0,56M vmalloc=500M
bootargs_3840M=mem=1961M mmz=ddr,0,0,56M vmalloc=500M
stdin=serial
stdout=serial
stderr=serial
"""


def make_uboot_env_block(env_str, block_size):
    """Create u-boot env block: CRC32(4) + key=value\\0 ... \\0 + padding

    U-Boot computes CRC32 over the entire block excluding the first 4 bytes
    (i.e. over env_data + padding zeros). We must build the full block first,
    then compute the CRC.
    """
    lines = [l.strip() for l in env_str.strip().splitlines() if l.strip()]
    env_data = b""
    for line in lines:
        env_data += line.encode('ascii') + b'\x00'
    env_data += b'\x00'  # final null terminator

    if 4 + len(env_data) > block_size:
        raise ValueError(f"Env block too large: {4 + len(env_data)} > {block_size}")

    # Build full block with placeholder CRC, then compute real CRC over [4:]
    raw = bytearray(struct.pack('<I', 0) + env_data)
    raw += bytearray(block_size - len(raw))

    crc = binascii.crc32(bytes(raw[4:])) & 0xFFFFFFFF
    # Patch CRC into first 4 bytes
    struct.pack_into('<I', raw, 0, crc)
    return bytes(raw)


def make_bootargs_bin(rsa_key=None, total_size=BOOTARGS_TOTAL_SIZE, variant="SMB400"):
    """Create bootargs.bin as raw u-boot env block (no ADVCA header).

    The Hisilicon bootloader reads bootargs.bin as a raw u-boot environment
    block: CRC32(4) + key=value\\0 ... \\0 + zero-padding.
    No ADVCA signature header is needed — the bootloader only checks the
    internal CRC32, not an RSA signature.
    """
    env = BOOTARGS_ENV
    phy = PHY_ADDR_BY_VARIANT[variant]
    env, n = re.subn(r'^phy_addr=.*$', f'phy_addr={phy}', env, flags=re.M)
    assert n == 1, f"phy_addr line not found in BOOTARGS_ENV (n={n})"
    env_block = make_uboot_env_block(env, total_size)
    assert len(env_block) == total_size, f"Env block size mismatch: {len(env_block)} vs {total_size}"

    # Verify CRC is correct
    stored_crc = struct.unpack_from('<I', env_block, 0)[0]
    computed_crc = binascii.crc32(env_block[4:]) & 0xFFFFFFFF
    assert stored_crc == computed_crc, f"CRC mismatch: stored=0x{stored_crc:08x} computed=0x{computed_crc:08x}"
    print(f"[+] U-boot env CRC32: 0x{stored_crc:08x} (OK)")

    return env_block


def make_root_rsa_pub_crc(rsa_key):
    """Create root_rsa_pub_crc.bin: modulus(256 BE) + exponent(4 LE) + CRC32(4)"""
    pub = rsa_key.publickey()
    n = pub.n
    e = pub.e

    # Modulus: 256 bytes, big-endian
    modulus = n.to_bytes(256, 'big')
    # Exponent: 4 bytes, little-endian
    exponent = struct.pack('<I', e)
    # CRC32 of modulus + exponent
    key_data = modulus + exponent
    crc = binascii.crc32(key_data) & 0xFFFFFFFF
    crc_bytes = struct.pack('<I', crc)

    result = key_data + crc_bytes
    print(f"[+] RSA modulus[0:8]: {modulus[:8].hex()}")
    print(f"[+] RSA exponent: 0x{e:x}")
    print(f"[+] CRC32: 0x{crc:08x}")
    return result


def main():
    variant = resolve_variant()
    print(f"[*] Board variant: {variant} (phy_addr={PHY_ADDR_BY_VARIANT[variant]})")
    outdir = os.path.dirname(os.path.abspath(__file__))
    usb_dir = os.path.join(outdir, "usb_boot_files")
    os.makedirs(usb_dir, exist_ok=True)

    key_file = os.path.join(usb_dir, "rsa_key.pem")

    # Generate or load RSA key
    if os.path.exists(key_file):
        print(f"[*] Loading existing RSA key from {key_file}")
        with open(key_file, 'rb') as f:
            rsa_key = RSA.import_key(f.read())
    else:
        # Use e=3 to match the internal Hisilicon bootloader RSA exponent
        print("[*] Generating RSA-2048 key pair (e=3, matching bootloader)...")
        rsa_key = RSA.generate(2048, e=3)
        with open(key_file, 'wb') as f:
            f.write(rsa_key.export_key())
        print(f"[+] Key saved to {key_file}")

    print(f"[*] Key size: {rsa_key.size_in_bits()} bits, e={rsa_key.e}")

    # Create root_rsa_pub_crc.bin
    print("\n[*] Creating root_rsa_pub_crc.bin...")
    pub_crc = make_root_rsa_pub_crc(rsa_key)
    pub_crc_path = os.path.join(usb_dir, "root_rsa_pub_crc.bin")
    with open(pub_crc_path, 'wb') as f:
        f.write(pub_crc)
    print(f"[+] Written: {pub_crc_path} ({len(pub_crc)} bytes)")

    # Create bootargs.bin (raw u-boot env block, no ADVCA header)
    print("\n[*] Creating bootargs.bin...")
    print(f"    variant={variant}  phy_addr={PHY_ADDR_BY_VARIANT[variant]}")
    bootargs = make_bootargs_bin(variant=variant)
    bootargs_path = os.path.join(usb_dir, "bootargs.bin")
    with open(bootargs_path, 'wb') as f:
        f.write(bootargs)
    print(f"[+] Written: {bootargs_path} ({len(bootargs)} bytes)")

    print("\n[*] USB boot files ready:")
    print(f"    {usb_dir}/")
    print(f"    ├── bootargs.bin      ({len(bootargs)} bytes)")
    print(f"    ├── root_rsa_pub_crc.bin ({len(pub_crc)} bytes)")
    print(f"    └── rsa_key.pem       (private key - keep safe)")
    print()
    print("[*] Instructions:")
    print("    1. Format USB drive as FAT32")
    print("    2. Copy bootargs.bin and root_rsa_pub_crc.bin to USB root")
    print("    3. Insert USB into device")
    print("    4. Short USB boot pin while powering on")
    print("    5. Device should boot with SELinux=permissive")


if __name__ == '__main__':
    main()
