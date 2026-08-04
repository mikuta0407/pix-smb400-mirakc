#!/system/bin/sh
# start_mirakc.sh — start mirakc (BS4K-capable) on SMB400.
#
# Replaces start_mirakurun.sh.  mirakc, mirakc-arib and dantto4k are all
# statically linked musl binaries, so the Alpine chroot, the bind mounts into
# it, the /dev node creation and Node.js are all gone.
#
# Requires root (ADB shell is root by default on SMB400).

MIRAKC=/data/local/tmp/mirakc
LOG=/data/local/tmp/mirakc.log
PIDFILE=/data/local/tmp/mirakc-start.pid

# --- Kill switch --------------------------------------------------------------
# Autostart is baked into the initramfs (init.pixboot.rc), so without this there
# would be no way to stop mirakc from coming up at boot short of reflashing the
# USB medium — which needs physical access to recover if it goes wrong.
# This file lives in /data, survives reboots, and can be created over ADB:
#
#     adb shell "touch /data/local/tmp/mirakc.disabled"     # stop autostarting
#     adb shell "rm -f /data/local/tmp/mirakc.disabled"     # start again
#
# Checked before anything else, so a disabled device is left completely alone
# (Android TV is not stopped, no processes are killed).
if [ -e /data/local/tmp/mirakc.disabled ]; then
    echo "[mirakc] /data/local/tmp/mirakc.disabled exists — not starting." >> "$LOG"
    exit 0
fi

# --- Let Android settle before touching anything -----------------------------
# init fires this service on `sys.boot_completed`, but Android is still starting
# services and apps at that point.  Running stop_android_tv.sh (which force-stops
# dozens of packages) and grabbing the tuner right then reboot-looped the device
# at the kernel level — /proc/uptime went backwards, so it was a panic or the
# hardware watchdog, not an Android soft restart.
#
# Every component was verified stable when the same stack is started by hand a
# few minutes after boot, so the race with the tail of the boot sequence is what
# matters, not any single component.
#
# Only applies when init started us; a manual run should not wait.
if [ -n "$MIRAKC_FROM_INIT" ]; then
    delay=${MIRAKC_BOOT_DELAY:-120}
    echo "[mirakc] started by init — waiting ${delay}s for Android to settle" >> "$LOG"
    sleep "$delay"
fi

# --- Preflight: start only if everything is present. -------------------------
# If anything is missing we exit WITHOUT stopping Android TV, so a
# not-yet-provisioned device is left completely untouched.
REQUIRED="
$MIRAKC/mirakc
$MIRAKC/mirakc-arib
$MIRAKC/config.yml
$MIRAKC/strings.yml
/data/local/tmp/dantto4k
/data/local/tmp/smb400-tuner.sh
/data/local/tmp/tuner-stream-bs-ng
/data/local/tmp/b61dec
"
missing=""
for f in $REQUIRED; do
    [ -e "$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
    echo "[mirakc] not starting — missing file(s):$missing" >> "$LOG"
    exit 1
fi

# Singleton.
if [ -f "$PIDFILE" ]; then
    existing=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
        echo "[mirakc] already running (pid=$existing), exiting." >> "$LOG"
        exit 0
    fi
fi
echo $$ > "$PIDFILE"

# --- Make sure nothing else owns the single physical tuner -------------------
# `stop` (not pkill) is required for init services — init respawns a service
# whose process is merely killed.
#
# MIRAKC_FROM_INIT is set by init.pixboot.rc, i.e. we ARE the `mirakc` service;
# stopping it then would kill our own process group.
if [ -z "$MIRAKC_FROM_INIT" ]; then
    stop mirakc 2>/dev/null || true
fi
# Legacy units provisioned with pix-smb400-mirakurun run Mirakurun from an init
# service of this name.  No-op on a device built from this repo.
stop mirakurun_proxy 2>/dev/null || true

# --- Allow unaligned memory access -------------------------------------------
# This kernel defaults /proc/cpu/alignment to 4 (= deliver SIGBUS).  dantto4k
# performs unaligned 64-bit loads while parsing MMT and dies with a bus error
# within ~1.3s of real BS4K input.  Mode 2 makes the kernel fix the access up
# in software instead.  Measured cost: ~3300 fixups per 20s of 33Mbps stream,
# i.e. negligible.  The setting is global and resets on reboot.
if [ -w /proc/cpu/alignment ]; then
    echo 2 > /proc/cpu/alignment
    echo "[mirakc] /proc/cpu/alignment set to 2 (fixup)" >> "$LOG"
else
    echo "[mirakc] WARNING: cannot write /proc/cpu/alignment — dantto4k will SIGBUS" >> "$LOG"
fi

# --- Neutralize crash_dump32 (zombie fork-bomb / brick prevention) -----------
# Carried over verbatim from start_mirakurun.sh (pix-smb400-mirakurun PR #6).
# A crashing native process forks crash_dump32 to ptrace it; under memory
# pressure these tangle into unreapable ptrace zombies and can self-fork into a
# brick that only a REBOOT clears.  Replacing crash_dump32 with a no-op makes
# crashes exit cleanly and be reaped normally.  Runtime bind-mount: /system
# stays read-only and untouched, and it disappears on reboot.
#
# NOTE: this bind mount is NOT one of the Alpine-chroot bind mounts that were
# dropped along with the chroot.  It must stay.
NOOP=/data/local/tmp/noop_crashdump
if ! grep -q " /system/bin/crash_dump32 " /proc/mounts 2>/dev/null; then
    printf '#!/system/bin/sh\nexit 0\n' > "$NOOP"
    chmod 755 "$NOOP"
    if mount --bind "$NOOP" /system/bin/crash_dump32 2>/dev/null; then
        echo "[mirakc] crash_dump32 neutralized (no-op bind-mount)" >> "$LOG"
    else
        echo "[mirakc] WARNING: could not bind-mount no-op over crash_dump32" >> "$LOG"
    fi
fi

# ACAS master key is required for BS4K descrambling (b61dec).
if [ ! -s /data/local/tmp/.acas_key ]; then
    echo "[mirakc] warning: /data/local/tmp/.acas_key missing — BS4K will be scrambled." >> "$LOG"
fi

# --- Free memory / release the OEM tuner -------------------------------------
# Also stops the OEM tuner services so b61dec can claim the ACAS smartcard.
export LOG
sh /data/local/tmp/stop_android_tv.sh

# --- Kill stale processes from a previous session ----------------------------
# A leftover tunertest blocks the next tune.
pkill -9 -f "lib/server\.js" 2>/dev/null || true
pkill -9 -f "Mirakurun:" 2>/dev/null || true
pkill -9 node 2>/dev/null || true
pkill -9 -f "tunertest_oem" 2>/dev/null || true
pkill -9 -f "tunertest" 2>/dev/null || true
pkill -9 -f "tuner-stream" 2>/dev/null || true
pkill -9 -f "b61dec" 2>/dev/null || true
pkill -9 -f "b21dec" 2>/dev/null || true
pkill -9 -f "dantto4k" 2>/dev/null || true
pkill -9 -f "$MIRAKC/mirakc" 2>/dev/null || true

# --- Brick-prevention watchdog -----------------------------------------------
# crash_guard kills crash_dump32 fork-bombs and reclaims memory before OOM.
#
# NOTE: its hard-floor branch only kills node / "Mirakurun:" / "lib/server.js",
# so it will NOT kill mirakc.  The crash_dump32 fork-bomb branch — the part that
# actually prevents bricking — is process-agnostic and still applies.
GUARD=/data/local/tmp/crash_guard.sh
GUARD_PID=/data/local/tmp/crash_guard.pid
guard_running=0
if [ -f "$GUARD_PID" ]; then
    gp=$(cat "$GUARD_PID" 2>/dev/null)
    if [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null; then
        guard_running=1
    fi
fi
if [ "$guard_running" = 0 ]; then
    setsid sh "$GUARD" >> /data/local/tmp/crash_guard.log 2>&1 &
    echo "[mirakc] crash_guard watchdog launched (pid=$!)" >> "$LOG"
else
    echo "[mirakc] crash_guard already running (pid=$gp)" >> "$LOG"
fi

# --- Orphaned tuner-process reaper -------------------------------------------
# When a viewer preempts a background job, the job's tuner-stream/tunertest
# processes survive as orphans and pile up.  See tuner_reaper.sh.
REAPER=/data/local/tmp/tuner_reaper.sh
REAPER_PID=""
if [ -x "$REAPER" ]; then
    LOG="$LOG" setsid sh "$REAPER" &
    REAPER_PID=$!
    echo "[mirakc] tuner reaper launched (pid=$REAPER_PID)" >> "$LOG"
else
    echo "[mirakc] WARNING: $REAPER missing — orphaned tuner processes will pile up" >> "$LOG"
fi

mkdir -p "$MIRAKC/epg"

echo "[mirakc] starting mirakc..." >> "$LOG"

# --- Launch -------------------------------------------------------------------
# mirakc validates every configured command with `which` at startup, so
# mirakc-arib and dantto4k must be reachable via PATH or given as absolute
# paths in config.yml.
#
# Run ONCE — intentionally NO restart loop.  On this device a crash-looping
# decoder can spawn a crash_dump32 fork-bomb and brick the box.  Recover by
# running this script again, or fall back to Mirakurun with
# `start mirakurun_proxy`.
export PATH=$MIRAKC:/data/local/tmp:$PATH
export MIRAKC_CONFIG=$MIRAKC/config.yml
export RUST_LOG=${RUST_LOG:-info}
"$MIRAKC/mirakc" >> "$LOG" 2>&1
code=$?

echo "[mirakc] process exited (code=$code) — not restarting (safe mode)." >> "$LOG"

# The reaper ignores SIGTERM (so a stray kill cannot disarm it), so use SIGKILL.
if [ -n "$REAPER_PID" ]; then
    kill -9 "$REAPER_PID" 2>/dev/null || true
    echo "[mirakc] tuner reaper stopped" >> "$LOG"
fi

rm -f "$PIDFILE" 2>/dev/null || true
exit "$code"
