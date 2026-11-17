#!/usr/bin/env bash
# install.sh — USB ブート済みの PIX-SMB400 / TU-BUHD100 に mirakc を入れて起動する。
#
#   ./install.sh [デバイスのIPアドレス]
#
# 何度実行してもよい（更新にも使える）。既存の config.yml は上書きしない。
# 上書きしたいときは OVERWRITE_CONFIG=1 ./install.sh <IP>
#
# Bluetooth を無効にするか聞かれる。聞かれたくなければ
#   BLUETOOTH=disable ./install.sh <IP>   （無効にする）
#   BLUETOOTH=keep    ./install.sh <IP>   （そのまま）

set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$KIT/payload"
TMP=/data/local/tmp
MIRAKC_DIR=$TMP/mirakc
PORT=40772

say()  { printf '\033[1m[*] %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 1. adb を用意する --------------------------------------------------------
find_adb() {
    if [ -x "$KIT/tools/platform-tools/adb" ]; then
        echo "$KIT/tools/platform-tools/adb"
    elif command -v adb >/dev/null 2>&1; then
        command -v adb
    fi
}

ADB=$(find_adb)
if [ -z "$ADB" ]; then
    say "adb が見つからないので、Google の公式配布 (platform-tools) をダウンロードします"
    url=https://dl.google.com/android/repository/platform-tools-latest-linux.zip
    mkdir -p "$KIT/tools"
    zip="$KIT/tools/platform-tools.zip"
    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "$zip" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$zip" "$url"
    else
        die "curl も wget も無いのでダウンロードできません。adb を入れてから再実行してください（例: sudo apt install adb）"
    fi
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$zip" -d "$KIT/tools"
    else
        python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$KIT/tools"
        chmod +x "$KIT/tools/platform-tools/adb"
    fi
    rm -f "$zip"
    ADB=$(find_adb)
    [ -n "$ADB" ] || die "adb の準備に失敗しました"
fi
ok "adb: $ADB"

# ---- 2. 接続 ------------------------------------------------------------------
IP="${1:-}"
if [ -z "$IP" ]; then
    read -r -p "デバイスの IP アドレスを入力してください (例 192.168.0.77): " IP
fi
IP="${IP%%:*}"
[ -n "$IP" ] || die "IP アドレスが空です"
T="$IP:5555"

say "$T に接続します"
connected=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    "$ADB" connect "$T" >/dev/null 2>&1 || true
    if [ "$("$ADB" -s "$T" get-state 2>/dev/null)" = "device" ]; then
        connected=1; break
    fi
    sleep 3
done
[ "$connected" = 1 ] || die "$T に接続できません。IP アドレスと、USB ブートで起動しているか（起動から 1 分ほど待ったか）を確認してください"

dev() { "$ADB" -s "$T" shell "$@"; }

# ---- 3. 状態チェック ----------------------------------------------------------
uid=$(dev id -u | tr -d '\r')
[ "$uid" = 0 ] || die "root で接続できていません (uid=$uid)。USB ブートではなく通常起動しています。USB メモリとブート手順を確認してください"

board=$(dev getprop pix.hw.boardname | tr -d '\r')
[ "$board" = "PIX-SMB400" ] || die "対応していない機種です (pix.hw.boardname=$board)"

if dev "grep -q '^service mirakc ' /init.pixboot.rc" 2>/dev/null; then
    ok "USB ブート (mirakc 版) で起動しています"
elif dev "grep -q 'mirakurun_proxy' /init.pixboot.rc" 2>/dev/null; then
    die "USB メモリの中身が Mirakurun 版です。このキットの USB フォルダのファイルに差し替えて再起動してから、もう一度実行してください"
else
    die "このキットの USB メモリで起動していないようです (/init.pixboot.rc に mirakc サービスが無い)"
fi

# ---- 4. ACAS キー -------------------------------------------------------------
KEY=""
if [ -f "$KIT/acas_key.txt" ]; then
    KEY=$(tr -d '[:space:]' < "$KIT/acas_key.txt")
    say "acas_key.txt からキーを読みました"
elif dev "test -s $TMP/.acas_key" 2>/dev/null; then
    ok "ACAS キーはデバイスに設定済みです（そのまま使います）"
else
    echo "BS4K を見るには ACAS キー（64 桁の 16 進数）が必要です。"
    echo "持っていなければ空のまま Enter（地デジ・BS は見られます。後から設定もできます）。"
    read -r -p "ACAS キー: " KEY
    KEY=$(printf '%s' "$KEY" | tr -d '[:space:]')
fi
if [ -n "$KEY" ]; then
    printf '%s' "$KEY" | grep -Eq '^[0-9a-fA-F]{64}$' || die "ACAS キーの形式が違います（64 桁の 16 進数）"
    dev "umask 077; echo '$KEY' > $TMP/.acas_key; chmod 600 $TMP/.acas_key"
    ok "ACAS キーを設定しました"
elif ! dev "test -s $TMP/.acas_key" 2>/dev/null; then
    warn "ACAS キーなしで続けます（BS4K はスクランブルのまま）"
fi

# ---- 5. 動いている mirakc を止める -------------------------------------------
# pkill -f は adb shell 自身にマッチして自殺するので PID を引いて kill する
say "動作中の mirakc があれば止めます"
dev "stop mirakc 2>/dev/null; true" || true
dev 'p=$(pgrep -f "mirakc/mirakc$" | head -1); [ -n "$p" ] && kill -TERM $p && sleep 3; true' || true
dev 'p=$(pgrep -f "tuner_reaper" | head -1); [ -n "$p" ] && kill -9 $p; true' || true

# ---- 6. ファイルを送る --------------------------------------------------------
say "バイナリを送ります（30MB ほど）"
dev "mkdir -p $MIRAKC_DIR/epg"
for f in tuner-stream-ng tuner-stream-bs tuner-stream-bs-ng b21dec b61dec dantto4k; do
    "$ADB" -s "$T" push "$PAYLOAD/bin/$f" "$TMP/$f" >/dev/null
done
for f in mirakc mirakc-arib; do
    "$ADB" -s "$T" push "$PAYLOAD/bin/$f" "$MIRAKC_DIR/$f" >/dev/null
done
dev "chmod 755 $TMP/tuner-stream-ng $TMP/tuner-stream-bs $TMP/tuner-stream-bs-ng \
    $TMP/b21dec $TMP/b61dec $TMP/dantto4k $MIRAKC_DIR/mirakc $MIRAKC_DIR/mirakc-arib"

# スクリプトは毎ブート initramfs から上書きされる。中身は同じなので、
# 再起動せずにすぐ動かすためだけに送る
for f in smb400-tuner.sh start_mirakc.sh tuner_reaper.sh stop_android_tv.sh crash_guard.sh; do
    "$ADB" -s "$T" push "$PAYLOAD/scripts/$f" "$TMP/$f" >/dev/null
done
dev "chmod 755 $TMP/smb400-tuner.sh $TMP/start_mirakc.sh $TMP/tuner_reaper.sh \
    $TMP/stop_android_tv.sh $TMP/crash_guard.sh"

"$ADB" -s "$T" push "$PAYLOAD/config/strings.yml" "$MIRAKC_DIR/strings.yml" >/dev/null
if dev "test -f $MIRAKC_DIR/config.yml" 2>/dev/null && [ "${OVERWRITE_CONFIG:-0}" != 1 ]; then
    ok "config.yml はデバイスにあるものをそのまま使います（上書きするなら OVERWRITE_CONFIG=1）"
else
    if dev "test -f $MIRAKC_DIR/config.yml" 2>/dev/null; then
        bak="config.yml.bak-$(date +%Y%m%d%H%M%S)"
        dev "cp $MIRAKC_DIR/config.yml $MIRAKC_DIR/$bak"
        say "既存の config.yml を $bak に退避しました"
    fi
    "$ADB" -s "$T" push "$PAYLOAD/config/config.yml" "$MIRAKC_DIR/config.yml" >/dev/null
    ok "config.yml を送りました（関東向け）"
fi
ok "ファイルの転送が終わりました"

# ---- 7. Bluetooth（任意） -----------------------------------------------------
# com.android.bluetooth が SIGABRT のクラッシュループを起こし、crash_dump32 が
# 溜まって本体が固まったことがある。mirakc には Bluetooth は要らない。
# pm disable は /data に記録されるので、USB を抜いた通常起動にも効く
BT_PKG=com.android.bluetooth
if dev "pm list packages -d" | tr -d '\r' | grep -qx "package:$BT_PKG"; then
    ok "Bluetooth は無効化済みです"
else
    choice="${BLUETOOTH:-ask}"
    if [ "$choice" = ask ]; then
        echo
        echo "Bluetooth を無効にしますか？（おすすめ）"
        echo "  Bluetooth のクラッシュがきっかけで本体が固まることがありました。mirakc には不要です。"
        echo "  ただし USB を抜いて普通の Android TV として使うときも Bluetooth（BT リモコンなど）が"
        echo "  使えなくなります。戻すときは: adb -s $T shell pm enable $BT_PKG"
        read -r -p "無効にする [Y/n]: " ans
        case "$ans" in [nN]*) choice=keep ;; *) choice=disable ;; esac
    fi
    if [ "$choice" = disable ]; then
        dev "pm disable $BT_PKG" >/dev/null
        if dev "pm list packages -d" | tr -d '\r' | grep -qx "package:$BT_PKG"; then
            ok "Bluetooth を無効にしました"
        else
            warn "Bluetooth を無効にできませんでした（このまま続けます）"
        fi
    else
        say "Bluetooth はそのままにします"
    fi
fi

# ---- 8. 起動 ------------------------------------------------------------------
if dev "test -e $TMP/mirakc.disabled" 2>/dev/null; then
    warn "自動起動が無効になっています ($TMP/mirakc.disabled がある)"
    warn "有効にするには: $ADB -s $T shell rm -f $TMP/mirakc.disabled"
    exit 0
fi

say "mirakc を起動します（Android TV の画面は止まります）"
dev "rm -f $TMP/mirakc-start.pid; setsid sh $TMP/start_mirakc.sh >/dev/null 2>&1 &"

http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O - "$1"
    else
        python3 -c 'import sys,urllib.request; print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())' "$1"
    fi
}

say "起動を待っています（最大 2 分）"
for _ in $(seq 1 40); do
    if v=$(http_get "http://$IP:$PORT/api/version" 2>/dev/null); then
        echo
        ok "mirakc が起動しました: $v"
        echo
        echo "  EPGStation などの Mirakurun の URL に次を設定してください:"
        echo "      http://$IP:$PORT"
        echo
        echo "  番組表 (EPG) が揃うまでには数十分かかります。"
        echo "  次回からは USB メモリを挿したまま電源を入れるだけで自動で起動します（起動後 2 分ほどかかります）。"
        exit 0
    fi
    sleep 3
done
warn "まだ応答がありません。ログを確認してください:"
warn "  $ADB -s $T shell tail -50 $TMP/mirakc.log"
exit 1
