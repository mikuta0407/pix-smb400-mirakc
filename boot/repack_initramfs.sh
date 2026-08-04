#!/usr/bin/env bash
# repack_initramfs.sh — 既存の initramfs_patched.uimg にオーバーレイを当て直す。
#
#   bash boot/repack_initramfs.sh <既存の.uimg> [出力先.uimg]
#
# build_initramfs.sh との違い:
#
#   build_initramfs.sh  ファームウェアの kernel.img を binwalk で展開した cpio が要る。
#                       init バイナリへのパッチもここで当てる。**初回構築用。**
#   repack_initramfs.sh **既に動いている .uimg** を材料にする。kernel.img も binwalk も
#                       不要で、init のパッチは既に当たっているものをそのまま使う。
#                       overlay を更新したいだけならこちらが速くて安全。
#
# 実機の USB メディアから直接持ってくることもできる:
#   adb pull /mnt/media_rw/sda1/initramfs_patched.uimg .
#
# 必要なもの: docker, python3, cpio, gzip
# TU-BUHD100 など OEM 個体でも、その個体で動いている .uimg を材料にすれば
# 機種差（default.prop の adb 設定など）はそのまま引き継がれる。

set -euo pipefail

SRC_UIMG="${1:-}"
if [ -z "$SRC_UIMG" ]; then
    echo "Usage: bash $(basename "$0") <existing.uimg> [output.uimg]"
    exit 1
fi
[ -f "$SRC_UIMG" ] || { echo "[!] not found: $SRC_UIMG"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/initramfs_overlay"
SRC_ABS="$(realpath "$SRC_UIMG")"
OUT="${2:-$SCRIPT_DIR/initramfs_patched.uimg}"
WORK_DIR="${WORK_DIR:-/tmp/smb400_repack_work}"

echo "[*] Source:  $SRC_ABS"
echo "[*] Overlay: $OVERLAY_DIR"
echo "[*] Output:  $OUT"
echo ""

# --- 1. uimg ヘッダを外して cpio を取り出す ---
rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR/root"
echo "[*] uimg を展開中..."
python3 - "$SRC_ABS" "$WORK_DIR/payload.gz" <<'PY'
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = open(src, 'rb').read()
magic, hcrc, tim, size, load, ep, dcrc, os_, arch, typ, comp = \
    struct.unpack('>IIIIIIIBBBB', d[:32])
if magic != 0x27051956:
    sys.exit(f"[!] not a u-boot image (magic=0x{magic:08x})")
name = d[32:64].rstrip(b'\0').decode()
print(f"    name={name!r} size={size} load=0x{load:08x} ep=0x{ep:08x} comp={comp}")
if comp != 1:
    sys.exit(f"[!] unexpected compression {comp} (expected 1 = gzip)")
open(dst, 'wb').write(d[64:64 + size])
PY

gunzip -c "$WORK_DIR/payload.gz" > "$WORK_DIR/payload.cpio"
(cd "$WORK_DIR/root" && cpio -idm --no-absolute-filenames -F ../payload.cpio 2>/dev/null)
echo "[+] 展開完了"

# --- 2. オーバーレイを適用 ---
echo "[*] オーバーレイを適用中..."

# default.prop は機種ごとに中身が違う（PIX-SMB400 と TU-BUHD100 で
# persist.sys.usb.config が異なる。→ VARIANTS.md）。ここを取り違えると
# 再起動後に ADB が上がらず、復旧に物理アクセスが要る。
# **材料の .uimg のものが実際に動いている設定なので、既定では残す。**
if [ "${OVERWRITE_DEFAULT_PROP:-0}" = "1" ]; then
    echo "    default.prop: overlay で上書き（OVERWRITE_DEFAULT_PROP=1）"
    cp "$OVERLAY_DIR/default.prop" "$WORK_DIR/root/default.prop"
else
    echo "    default.prop: 元の .uimg のものを維持（上書きするなら OVERWRITE_DEFAULT_PROP=1）"
    if ! diff -q "$WORK_DIR/root/default.prop" "$OVERLAY_DIR/default.prop" >/dev/null 2>&1; then
        echo "    [i] overlay と差分あり:"
        diff "$OVERLAY_DIR/default.prop" "$WORK_DIR/root/default.prop" | sed 's/^/        /' || true
    fi
fi

cp "$OVERLAY_DIR/dhclient.conf"      "$WORK_DIR/root/dhclient.conf"
cp "$OVERLAY_DIR/init.pixboot.rc"    "$WORK_DIR/root/init.pixboot.rc"
cp "$OVERLAY_DIR/init_pix_netdbg.sh" "$WORK_DIR/root/init_pix_netdbg.sh"
mkdir -p "$WORK_DIR/root/initrc"
cp "$OVERLAY_DIR/initrc/logd.rc"     "$WORK_DIR/root/initrc/logd.rc"

# init.pixboot.rc の `on post-fs-data` の copy 行と 1:1 で対応させること
cp "$OVERLAY_DIR/start_mirakc.sh"    "$WORK_DIR/root/start_mirakc.sh"
cp "$OVERLAY_DIR/tuner_reaper.sh"    "$WORK_DIR/root/tuner_reaper.sh"
cp "$OVERLAY_DIR/crash_guard.sh"     "$WORK_DIR/root/crash_guard.sh"
cp "$OVERLAY_DIR/stop_android_tv.sh" "$WORK_DIR/root/stop_android_tv.sh"
cp "$OVERLAY_DIR/smb400_tuner.sh"    "$WORK_DIR/root/smb400_tuner.sh"

# Mirakurun 版から移行する場合、start_proxy.sh が残っていると紛らわしいので消す。
# init.pixboot.rc がもう参照していないので、あっても実害は無い。
rm -f "$WORK_DIR/root/start_proxy.sh"

# init.rc への import 挿入（冪等）
if ! grep -q 'import /init.pixboot.rc' "$WORK_DIR/root/init.rc"; then
    sed -i '0,/^import \/init\.usb\.rc$/s||import /init.usb.rc\nimport /init.pixboot.rc|' \
        "$WORK_DIR/root/init.rc"
    echo "[+] init.rc: import /init.pixboot.rc を挿入"
else
    echo "[=] init.rc: import /init.pixboot.rc は既に存在"
fi
echo "[+] オーバーレイ適用完了"

# --- 3. 健全性チェック ---
echo "[*] 健全性チェック..."
fail=0
[ -x "$WORK_DIR/root/init" ] || { echo "[!] /init が無い、または実行可能でない"; fail=1; }
# ADB が上がらなくなると復旧に物理アクセスが要るので、ここは厳しく見る
for prop in 'ro.debuggable=1' 'ro.adb.secure=0' 'service.adb.tcp.port=5555'; do
    grep -q "^$prop$" "$WORK_DIR/root/default.prop" || { echo "[!] default.prop に $prop が無い"; fail=1; }
done
grep -q '^persist.sys.usb.config=' "$WORK_DIR/root/default.prop" || { echo "[!] default.prop に persist.sys.usb.config が無い"; fail=1; }
# init.pixboot.rc の copy 行と、実際に置いたファイルの対応を検証
while read -r src; do
    [ -f "$WORK_DIR/root/$src" ] || { echo "[!] init.pixboot.rc が copy する /$src が initramfs に無い"; fail=1; }
done < <(grep -oP '^\s*copy /\K[^\s]+' "$WORK_DIR/root/init.pixboot.rc" || true)
# 起動サービスが実在するスクリプトを指しているか
svc=$(grep -oP '^service \S+ /system/bin/sh \K\S+' "$WORK_DIR/root/init.pixboot.rc" | head -1 || true)
if [ -n "$svc" ]; then
    base=$(basename "$svc")
    [ -f "$WORK_DIR/root/$base" ] || { echo "[!] サービスが指す $svc の元 (/$base) が initramfs に無い"; fail=1; }
    echo "    boot service -> $svc"
fi
[ "$fail" = 0 ] || { echo "[!] チェックに失敗したので中断します。"; exit 1; }
echo "[+] チェック OK"

# --- 4. パーミッション ---
find "$WORK_DIR/root" -name "*.rc" -print0 | xargs -0 -r chmod 644
find "$WORK_DIR/root" -name "*.sh" -print0 | xargs -0 -r chmod 755
chmod 755 "$WORK_DIR/root/init"
chmod 644 "$WORK_DIR/root/default.prop" "$WORK_DIR/root/dhclient.conf"

# --- 5. cpio + uimg を作る ---
echo "[*] Docker で uimg をビルド中..."
mkdir -p "$(dirname "$OUT")"
docker run --rm \
    -v "$WORK_DIR/root:/initramfs_work" \
    -v "$(cd "$(dirname "$OUT")" && pwd):/out" \
    ubuntu:22.04 bash -c "
set -e
apt-get update -qq && apt-get install -y -qq u-boot-tools cpio gzip 2>/dev/null
cd /initramfs_work
find . | sort | cpio -o -H newc --owner=root:root 2>/dev/null | gzip -9 > /tmp/x.cpio.gz
mkimage -A arm -O linux -T ramdisk -C gzip \
    -a 0x04000000 -e 0x04000000 -n 'patched-initramfs' \
    -d /tmp/x.cpio.gz /out/$(basename "$OUT")
ls -l /out/$(basename "$OUT")
"

echo ""
echo "[+] 完了: $OUT"
echo ""
echo "USB メディアへ書き戻す（実機の USB は ADB から見える）:"
echo "    adb shell cp /mnt/media_rw/sda1/initramfs_patched.uimg \\"
echo "                 /mnt/media_rw/sda1/initramfs_patched.uimg.bak"
echo "    adb push $OUT /mnt/media_rw/sda1/initramfs_patched.uimg"
echo "    adb shell sync"
echo "    adb reboot"
echo ""
echo "⚠️  起動しなくなった場合、復旧には筐体への物理アクセスが必要です"
echo "    （USB メディアを外す / .bak を書き戻す）。"
