# PIX-SMB400 mirakc (BS4K) — デプロイ & 運用 Makefile
#
# 前提: デバイスが USB ブートで起動し ADB ルート取得済みであること（BOOT.md）。
#
# 典型的な操作:
#   make push-all           バイナリ・スクリプト・設定を一括更新
#   make start              mirakc 起動
#   make status             サービス／チューナーの状態を表示
#   make test-bs4k          BS4K が MPEG-TS で出るか確認
#   make stop               停止

# ---------- 変更可能な設定 ----------
# ADB_TARGET 未指定時は adb devices から自動検出
# 複数台接続時は明示指定: make <target> ADB_TARGET=192.168.0.77:5555
ifndef ADB_TARGET
  _DETECTED := $(shell adb devices 2>/dev/null | awk '/\tdevice$$/{print $$1}')
  ifeq ($(words $(_DETECTED)),0)
    $(error No ADB device connected. Run: adb connect <ip>:<port>)
  else ifneq ($(words $(_DETECTED)),1)
    $(error Multiple ADB devices detected: $(_DETECTED) — set ADB_TARGET=<device>)
  else
    ADB_TARGET := $(_DETECTED)
  endif
endif
ADB        := adb -s $(ADB_TARGET)
DEVICE_IP  := $(firstword $(subst :, ,$(ADB_TARGET)))
DEVICE_TMP := /data/local/tmp
MIRAKC_DIR := $(DEVICE_TMP)/mirakc
PORT       ?= 40772

# 動作確認に使う BS4K チャンネル（TLV ストリーム ID）
TEST_BS4K  ?= 45328
TEST_GR    ?= 27

# チューナーバイナリのビルド設定（bin/ に同梱済みなので通常は不要）
# 要件: gcc-arm-linux-gnueabi, libssl-dev
CC_ARM       ?= arm-linux-gnueabi-gcc
ANDROID_LIBS := android-libs
# _TIME_BITS=32 / _FILE_OFFSET_BITS=32: 新しい Debian/Ubuntu のクロスツールチェーンは
# 64-bit time_t がデフォルトで __gettimeofday64 等を要求するが、Android bionic の
# libc.so は 32-bit time_t のシンボルしか持たないため明示的に 32-bit へ。
CFLAGS_ARM   := -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3 \
                -pie -fPIE -fno-stack-protector -nostartfiles \
                -D_TIME_BITS=32 -D_FILE_OFFSET_BITS=32 \
                -Wl,-dynamic-linker,/system/bin/linker \
                -L$(ANDROID_LIBS) -Wl,-rpath-link,$(ANDROID_LIBS)
# ------------------------------------

.PHONY: build-bins android-libs \
        push-all push-bins push-scripts push-config \
        start stop restart status log test test-bs4k test-gr \
        services programs clean-epg help

# ---- ビルド (src/ → bin/) ----
# bin/ にはビルド済みの armv7 バイナリを同梱してあるので、通常は実行不要。
# 作り直したいときだけ使う。

# デバイスから Android システムライブラリを取得（bionic にリンクするため）
android-libs:
	@mkdir -p $(ANDROID_LIBS)
	@for lib in libc.so libdl.so ld-android.so libssl.so libcrypto.so libm.so; do \
	    if [ ! -f $(ANDROID_LIBS)/$$lib ]; then \
	        echo "[*] pull /system/lib/$$lib"; \
	        $(ADB) pull /system/lib/$$lib $(ANDROID_LIBS)/$$lib; \
	    fi; \
	done

build-bins: android-libs
	@mkdir -p bin
	@echo "[*] tuner-stream-ng (GR/ISDB-T)..."
	$(CC_ARM) $(CFLAGS_ARM) \
	    src/startup.c src/tuner-stream-ng.c \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/tuner-stream-ng
	@echo "[*] tuner-stream-bs-ng (BS4K/ISDB-S3)..."
	$(CC_ARM) $(CFLAGS_ARM) \
	    src/startup.c src/tuner-stream-bs-ng.c \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/tuner-stream-bs-ng
	@echo "[*] b61dec (ACAS descrambler)..."
	$(CC_ARM) $(CFLAGS_ARM) -Wl,--no-as-needed \
	    -isystem /usr/include -isystem include \
	    src/startup.c src/b61dec.c \
	    $(ANDROID_LIBS)/libssl.so $(ANDROID_LIBS)/libcrypto.so \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so \
	    $(ANDROID_LIBS)/libm.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/b61dec
	@echo "[*] tuner-stream-bs (BS/ISDB-S)..."
	$(CC_ARM) $(CFLAGS_ARM) \
	    src/startup.c src/tuner-stream-bs.c \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/tuner-stream-bs
	@echo "[*] b21dec (MULTI2 descrambler)..."
	$(CC_ARM) $(CFLAGS_ARM) -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -Wl,--no-as-needed \
	    src/startup.c src/b21dec.c \
	    $(ANDROID_LIBS)/libc.so $(ANDROID_LIBS)/libdl.so $(ANDROID_LIBS)/ld-android.so \
	    -o bin/b21dec
	@echo "[+] Built the 5 tuner binaries."
	@echo "    mirakc / mirakc-arib / dantto4k は別途ビルドする → README.md"

# ---- デプロイ ----

push-bins:
	@echo "[*] Pushing binaries..."
	$(ADB) shell mkdir -p $(MIRAKC_DIR)/epg
	$(ADB) push bin/tuner-stream-ng    $(DEVICE_TMP)/tuner-stream-ng
	$(ADB) push bin/tuner-stream-bs    $(DEVICE_TMP)/tuner-stream-bs
	$(ADB) push bin/tuner-stream-bs-ng $(DEVICE_TMP)/tuner-stream-bs-ng
	$(ADB) push bin/b21dec             $(DEVICE_TMP)/b21dec
	$(ADB) push bin/b61dec             $(DEVICE_TMP)/b61dec
	$(ADB) push bin/dantto4k           $(DEVICE_TMP)/dantto4k
	$(ADB) push bin/mirakc             $(MIRAKC_DIR)/mirakc
	$(ADB) push bin/mirakc-arib        $(MIRAKC_DIR)/mirakc-arib
	$(ADB) shell chmod 755 \
	    $(DEVICE_TMP)/tuner-stream-ng $(DEVICE_TMP)/tuner-stream-bs \
	    $(DEVICE_TMP)/tuner-stream-bs-ng $(DEVICE_TMP)/b21dec \
	    $(DEVICE_TMP)/b61dec $(DEVICE_TMP)/dantto4k \
	    $(MIRAKC_DIR)/mirakc $(MIRAKC_DIR)/mirakc-arib

# NOTE: smb400-tuner.sh / crash_guard.sh / stop_android_tv.sh / start_mirakc.sh /
# tuner_reaper.sh は initramfs が毎ブート上書きする（init.pixboot.rc の
# `on post-fs-data`）。ここで push するのは再起動までの一時的な適用。
# 恒久化するには initramfs を作り直すこと → BOOT.md
push-scripts:
	@echo "[*] Pushing scripts (NOTE: overwritten by initramfs on next boot)..."
	$(ADB) push scripts/smb400-tuner.sh    $(DEVICE_TMP)/smb400-tuner.sh
	$(ADB) push scripts/start_mirakc.sh    $(DEVICE_TMP)/start_mirakc.sh
	$(ADB) push scripts/tuner_reaper.sh    $(DEVICE_TMP)/tuner_reaper.sh
	$(ADB) push scripts/stop_android_tv.sh $(DEVICE_TMP)/stop_android_tv.sh
	$(ADB) push scripts/crash_guard.sh     $(DEVICE_TMP)/crash_guard.sh
	$(ADB) shell chmod 755 \
	    $(DEVICE_TMP)/smb400-tuner.sh $(DEVICE_TMP)/start_mirakc.sh \
	    $(DEVICE_TMP)/tuner_reaper.sh $(DEVICE_TMP)/stop_android_tv.sh \
	    $(DEVICE_TMP)/crash_guard.sh

push-config:
	@echo "[*] Pushing config..."
	$(ADB) shell mkdir -p $(MIRAKC_DIR)/epg
	$(ADB) push config/config.yml  $(MIRAKC_DIR)/config.yml
	$(ADB) push config/strings.yml $(MIRAKC_DIR)/strings.yml

push-all: push-bins push-scripts push-config
	@echo "[+] Done. Run 'make start' to launch mirakc."

# ---- 起動・停止 ----

start: stop
	@echo "[*] Starting mirakc..."
	$(ADB) shell "rm -f $(DEVICE_TMP)/mirakc-start.pid; \
	    setsid sh $(DEVICE_TMP)/start_mirakc.sh >/dev/null 2>&1 &"
	@echo "[*] 起動を待っています（最大 ~60 秒）..."
	@ok=0; for i in $$(seq 1 30); do \
	    if curl -s --max-time 5 http://$(DEVICE_IP):$(PORT)/api/version >/dev/null 2>&1; then ok=1; break; fi; \
	    sleep 2; \
	done; \
	if [ $$ok = 1 ]; then \
	    printf "[+] mirakc is up: "; curl -s --max-time 5 http://$(DEVICE_IP):$(PORT)/api/version; echo; \
	else \
	    echo "(まだ応答がありません — 'make log' で確認してください)"; \
	fi

# `stop mirakc` は init サービスを止める。手動起動分は PID を引いて TERM。
# pkill -f を adb shell のワンライナーに書くと、adb shell 自身のコマンドライン
# がパターンにマッチして自殺するので使わないこと。
stop:
	@echo "[*] Stopping mirakc..."
	-$(ADB) shell "stop mirakc 2>/dev/null; true"
	-$(ADB) shell 'p=$$(pgrep -f "mirakc/mirakc$$" | head -1); \
	    [ -n "$$p" ] && kill -TERM $$p; sleep 3; true'
	-$(ADB) shell 'p=$$(pgrep -f "tuner_reaper" | head -1); \
	    [ -n "$$p" ] && kill -9 $$p; true'
	@echo "Stopped."

restart: stop start

# ---- 確認 ----

status:
	@printf "version : "; curl -s --max-time 5 http://$(DEVICE_IP):$(PORT)/api/version || echo "(down)"; echo
	@printf "tuner   : "; curl -s --max-time 5 http://$(DEVICE_IP):$(PORT)/api/tuners \
	    | python3 -c "import sys,json;t=json.load(sys.stdin)[0];print('free' if t['isFree'] else 'busy', '/ fault' if t['isFault'] else '')" 2>/dev/null || echo "(n/a)"
	@printf "services: "; curl -s --max-time 10 http://$(DEVICE_IP):$(PORT)/api/services \
	    | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo "(n/a)"
	@printf "programs: "; curl -s --max-time 20 http://$(DEVICE_IP):$(PORT)/api/programs \
	    | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo "(n/a)"
	@printf "memory  : "; $(ADB) shell "grep MemAvailable /proc/meminfo" 2>/dev/null || true
	@printf "align   : "; $(ADB) shell "grep 'User faults' /proc/cpu/alignment" 2>/dev/null || true

log:
	$(ADB) shell "tail -50 $(DEVICE_TMP)/mirakc.log"

services:
	@curl -s --max-time 15 http://$(DEVICE_IP):$(PORT)/api/services | python3 -c "\
import sys,json;\
[print(f\"{s['id']:>12}  {s['channel']['type']:<5} {s['channel']['channel']:<7} {s['name']}\") \
 for s in sorted(json.load(sys.stdin), key=lambda x:(x['channel']['type'],x['channel']['channel'],x['id']))]"

programs:
	@curl -s --max-time 25 http://$(DEVICE_IP):$(PORT)/api/programs | python3 -c "\
import sys,json,collections;\
d=json.load(sys.stdin);\
print('total', len(d));\
[print(f'  serviceId {k}: {v}') for k,v in sorted(collections.Counter(p['serviceId'] for p in d).items())]"

# BS4K を 12 秒受信して先頭バイトを表示。
#   remux 成功 (MPEG-TS) : 47 ...       ← 期待値
#   生 TLV・復号済み      : 7f 02 / 7f 03
#   未復号                : 7f ff       ← ACAS キーを疑う
test-bs4k:
	@echo "Streaming BS4K $(TEST_BS4K) for 12s..."
	@curl -s --max-time 12 http://$(DEVICE_IP):$(PORT)/api/channels/BS4K/$(TEST_BS4K)/stream \
	    | od -v -A d -t x1 2>/dev/null | head -2

test-gr:
	@echo "Streaming GR $(TEST_GR) for 8s..."
	@curl -s --max-time 8 http://$(DEVICE_IP):$(PORT)/api/channels/GR/$(TEST_GR)/stream \
	    | od -v -A d -t x1 2>/dev/null | head -2

test: test-bs4k

# EPG キャッシュを消して次回起動時に取り直させる
clean-epg:
	$(ADB) shell "rm -f $(MIRAKC_DIR)/epg/*.json"
	@echo "[+] EPG cache cleared. Restart mirakc to rescan."

# ---- ヘルプ ----

help:
	@echo ""
	@echo "PIX-SMB400 mirakc (BS4K) デプロイ Makefile"
	@echo ""
	@echo "  make push-all       バイナリ・スクリプト・設定を一括デプロイ"
	@echo "  make push-bins      バイナリのみ"
	@echo "  make push-scripts   スクリプトのみ（※再起動で initramfs に戻される）"
	@echo "  make push-config    設定のみ"
	@echo "  make start          mirakc 起動"
	@echo "  make stop           停止"
	@echo "  make restart        再起動"
	@echo "  make status         状態表示（サービス数・番組数・メモリ）"
	@echo "  make log            ログ確認 (tail -50)"
	@echo "  make services       登録サービス一覧"
	@echo "  make programs       EPG 番組数"
	@echo "  make test-bs4k      BS4K ストリーム疎通（先頭が 47 なら remux 成功）"
	@echo "  make test-gr        GR ストリーム疎通"
	@echo "  make clean-epg      EPG キャッシュ削除"
	@echo "  make build-bins     src/ からチューナーバイナリを再ビルド（通常不要）"
	@echo ""
	@echo "接続先: $(ADB_TARGET)  (変更: make start ADB_TARGET=192.168.0.77:5555)"
	@echo ""
