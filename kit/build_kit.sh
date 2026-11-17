#!/usr/bin/env bash
# build_kit.sh — 「展開して USB に入れて、インストーラを実行するだけ」の zip を作る。
#
#   bash kit/build_kit.sh --pix-smb400 <ファーム> [--tu-buhd100 <ファーム>] [--out <dir>]
#
# <ファーム> には、その機種の公式ファームウェアから取り出した次のどれかを渡す:
#
#   boot.img（= kernel.img）     initramfs を自動で取り出し、init にパッチを当てて作る
#   復号済みのアップデート zip   中の boot.img を使う
#   initramfs の cpio            binwalk などで取り出し済みのもの
#   initramfs_patched.uimg       既に USB ブートで動いているもの。overlay だけ当て直す
#                                （機種差の設定はそのまま引き継ぐ。いちばん確実）
#
# 機種は 1 つだけでもよい。指定した機種のフォルダだけ作る。
# ファームウェアは機種ごとに別物なので、機種を跨いで流用しないこと（→ VARIANTS.md）。
#
# 出力: dist/pix-smb400-mirakc-kit-<日付>-<commit>.zip
#   USB/<機種>/   USB メモリに入れる 3 ファイル（入力したファームウェアから作る）
#   payload/      本体に送るバイナリ・スクリプト・設定
#   install.*     Windows / Linux 用インストーラ
#
# 必要なもの: docker, python3, cpio, gzip, zip

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SMB_SRC=""
TU_SRC=""
OUT_DIR="$REPO/dist"

usage() { sed -n 2,25p "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --pix-smb400)  SMB_SRC="$(realpath "$2")"; shift 2 ;;
        --tu-buhd100)  TU_SRC="$(realpath "$2")"; shift 2 ;;
        --out)         OUT_DIR="$(realpath -m "$2")"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) echo "unknown option: $1"; usage ;;
    esac
done
[ -n "$SMB_SRC$TU_SRC" ] || usage
for t in docker python3 cpio gzip zip; do
    command -v "$t" >/dev/null 2>&1 || { echo "[!] $t が必要です"; exit 1; }
done

VERSION="$(date +%Y%m%d)-$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo nogit)"
if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    VERSION="$VERSION-dirty"
fi
NAME="pix-smb400-mirakc-kit-$VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$NAME"
mkdir -p "$STAGE"

echo "[*] $NAME"

# ---- USB ブート用の鍵と bootargs.bin -----------------------------------------
# 鍵はキットごとに新しく作る。BootROM は USB 上の公開鍵をそのまま使うので、
# どの鍵でもよい。秘密鍵（rsa_key.pem）はキットに入れない。
echo "[*] bootargs.bin / root_rsa_pub_crc.bin を生成"
mkdir -p "$WORK/usbgen"
cp "$REPO/boot/make_usb_boot.py" "$WORK/usbgen/"
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$WORK/usbgen:/w" python:3.11-slim sh -c '
set -e
pip install -q --user pycryptodome 2>/dev/null
cd /w
for v in SMB400 TU-BUHD100; do
    python3 make_usb_boot.py --variant "$v" >/dev/null
    mkdir -p "out/$v"
    cp usb_boot_files/bootargs.bin usb_boot_files/root_rsa_pub_crc.bin "out/$v/"
done
'

# ---- initramfs -----------------------------------------------------------------
is_uimg() { [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" = 27051956 ]; }

# make_initramfs <入力> <出力.uimg> <ログ名>
make_initramfs() {
    local src="$1" out="$2" tag="$3"
    if is_uimg "$src"; then
        echo "    USB ブート用の .uimg なので overlay を当て直す"
        WORK_DIR="$WORK/repack-$tag" bash "$REPO/boot/repack_initramfs.sh" "$src" "$out" \
            > "$WORK/$tag.log" 2>&1 || { cat "$WORK/$tag.log"; exit 1; }
    else
        python3 "$REPO/kit/extract_initramfs.py" "$src" "$WORK/$tag.cpio" | sed 's/^/    /'
        # build_initramfs.sh は出力先が boot/initramfs_patched.uimg 固定（.gitignore 済み）
        WORK_DIR="$WORK/build-$tag" bash "$REPO/boot/build_initramfs.sh" "$WORK/$tag.cpio" \
            > "$WORK/$tag.log" 2>&1 || { cat "$WORK/$tag.log"; exit 1; }
        mv "$REPO/boot/initramfs_patched.uimg" "$out"
    fi
}

if [ -n "$SMB_SRC" ]; then
    echo "[*] PIX-SMB400: $SMB_SRC"
    d="$STAGE/USB/PIX-SMB400"; mkdir -p "$d"
    make_initramfs "$SMB_SRC" "$d/initramfs_patched.uimg" smb400
    cp "$WORK/usbgen/out/SMB400/"* "$d/"
fi
if [ -n "$TU_SRC" ]; then
    echo "[*] TU-BUHD100: $TU_SRC"
    d="$STAGE/USB/TU-BUHD100"; mkdir -p "$d"
    make_initramfs "$TU_SRC" "$d/initramfs_patched.uimg" tu-buhd100
    cp "$WORK/usbgen/out/TU-BUHD100/"* "$d/"
fi

for d in "$STAGE"/USB/*/; do
    for f in bootargs.bin root_rsa_pub_crc.bin initramfs_patched.uimg; do
        [ -s "$d/$f" ] || { echo "[!] $d$f が作れていない"; exit 1; }
    done
done

# ---- 本体に送るもの -------------------------------------------------------------
mkdir -p "$STAGE/payload/bin" "$STAGE/payload/scripts" "$STAGE/payload/config"
cp "$REPO"/bin/{tuner-stream-ng,tuner-stream-bs,tuner-stream-bs-ng,b21dec,b61dec,dantto4k,mirakc,mirakc-arib,SHA256SUMS} \
    "$STAGE/payload/bin/"
(cd "$STAGE/payload/bin" && sha256sum -c --quiet SHA256SUMS)
cp "$REPO"/scripts/{smb400-tuner.sh,start_mirakc.sh,tuner_reaper.sh,stop_android_tv.sh,crash_guard.sh} \
    "$STAGE/payload/scripts/"
# 毎ブート initramfs から上書きされるものと同じであることを確かめる
for f in start_mirakc.sh tuner_reaper.sh stop_android_tv.sh crash_guard.sh; do
    cmp -s "$REPO/scripts/$f" "$REPO/boot/initramfs_overlay/$f" \
        || { echo "[!] scripts/$f と initramfs_overlay/$f が違う"; exit 1; }
done
cmp -s "$REPO/scripts/smb400-tuner.sh" "$REPO/boot/initramfs_overlay/smb400_tuner.sh" \
    || { echo "[!] scripts/smb400-tuner.sh と initramfs_overlay/smb400_tuner.sh が違う"; exit 1; }
cp "$REPO"/config/{config.yml,strings.yml} "$STAGE/payload/config/"

# ---- インストーラと文書 --------------------------------------------------------
cp "$REPO/kit/files/install.sh" "$STAGE/"
chmod 755 "$STAGE/install.sh"
cp -r "$REPO/LICENSE" "$REPO/NOTICE" "$REPO/LICENSES" "$STAGE/"

# Windows 側のファイルは CRLF。install.ps1 は Windows PowerShell 5.1 が
# 日本語を読めるよう UTF-8 BOM 付きにする。README.txt もメモ帳向けに BOM を付ける
python3 - "$REPO/kit/files" "$STAGE" "$VERSION" <<'PY'
import sys, pathlib
src, dst = map(pathlib.Path, sys.argv[1:3])
ver = sys.argv[3]
def crlf(t): return t.replace('\r\n', '\n').replace('\n', '\r\n')
for name, bom in [('install.ps1', True), ('install.bat', False), ('README.txt', True)]:
    t = (src / name).read_text(encoding='utf-8').replace('@@VERSION@@', ver)
    if name == 'install.bat':
        t.encode('ascii')  # .bat は ASCII 限定（コードページ問題を避ける）
    (dst / name).write_bytes((b'\xef\xbb\xbf' if bom else b'') + crlf(t).encode('utf-8'))
PY

# ---- zip -----------------------------------------------------------------------
mkdir -p "$OUT_DIR"
ZIP="$OUT_DIR/$NAME.zip"
rm -f "$ZIP"
(cd "$WORK" && zip -q -r -X "$ZIP" "$NAME")
echo ""
echo "[+] 完了: $ZIP ($(du -h "$ZIP" | cut -f1))"
(cd "$WORK" && find "$NAME" -type f | sort | sed 's/^/    /')
echo ""
echo "使い方は zip の中の README.txt を参照。"
