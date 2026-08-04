#!/system/bin/sh
# tuner_reaper.sh — reap orphaned tuner-pipeline processes.
#
# When a web viewer preempts a background EPG job (priority 0 beats -1) mirakc
# tears down the job's tuner, but the pipeline that smb400-tuner.sh started in
# the background survives: `tuner-stream-bs` and the `tunertest` it spawned keep
# running, and a zombie [tunertest] can be left behind too.  These accumulate and
# the leftovers are exactly what used to block the next tune under Mirakurun
# (hence the pkill pile in start_mirakurun.sh).
#
# Detection rule: in a healthy pipeline every one of these processes has mirakc
# or smb400-tuner.sh as an ancestor, so its PPID is never 1.  Once the parent is
# gone the kernel reparents the orphan to init, so **PPID == 1 means orphaned**.
# Killing an orphan makes its own children orphans, which the next pass reaps.
#
# Started by start_mirakc.sh and killed with it.  Deliberately does NOT touch
# crash_guard.sh, so falling back to Mirakurun stays a one-liner.

POLL=${POLL:-20}
LOG=${LOG:-/data/local/tmp/mirakc.log}

# Basenames only.  `mirakc` itself is excluded on purpose: it is started by
# start_mirakc.sh and would look orphaned if that script ever exits first.
TARGETS="tunertest tunertest_oem tuner-stream-ng tuner-stream-bs tuner-stream-bs-ng b61dec b21dec dantto4k"

trap '' TERM INT

echo "[reaper] started pid=$$ POLL=${POLL}s" >> "$LOG"

while true; do
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        [ "$pid" = "$$" ] && continue

        # Read comm (the kernel's name for the process) rather than cmdline, so
        # a zombie — whose cmdline is empty — is still matched.
        comm=$(cat "$p/comm" 2>/dev/null) || continue
        [ -z "$comm" ] && continue

        match=0
        for t in $TARGETS; do
            [ "$comm" = "$t" ] && { match=1; break; }
        done
        [ "$match" = 0 ] && continue

        # PPid is the 3rd line-ish field of /proc/<pid>/status.
        ppid=$(grep -m1 '^PPid:' "$p/status" 2>/dev/null | tr -dc '0-9')
        [ -z "$ppid" ] && continue

        if [ "$ppid" = "1" ]; then
            state=$(grep -m1 '^State:' "$p/status" 2>/dev/null | cut -d: -f2 | tr -d ' \t')
            echo "[reaper] orphan $comm pid=$pid state=$state — killing" >> "$LOG"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    sleep "$POLL"
done
