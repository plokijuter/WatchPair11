#!/bin/bash
# PLAN B: Symlink approach
#
# INSIGHT: xpcproxyhook only triggers DYLD_INSERT_LIBRARIES if
# /var/jb/System/Library/SysBins/<binary> exists (access F_OK check).
# But it can be a SYMLINK to the real Apple binary.
#
# Flow:
#   1. Create symlink /var/jb/System/Library/SysBins/nanoregistryd -> /usr/libexec/nanoregistryd
#   2. Via bindfs, /System/Library/VideoCodecs/SysBins/nanoregistryd also resolves to the symlink
#   3. xpcproxyhook sees the path, access() succeeds (follows symlink)
#   4. xpcproxyhook rewrites spawn path AND sets DYLD_INSERT_LIBRARIES=generalhook.dylib
#   5. posix_spawn resolves symlink to real Apple nanoregistryd (trust level 4)
#   6. Kernel/sandbox accept the real Apple binary (trust intact)
#   7. generalhook.dylib is injected via DYLD_INSERT → loads TweakInject → loads WatchPair11
#   8. WatchPair11 has nanoregistryd in filter → hooks fire
#
# Advantages: no re-signing needed, trust level preserved, zero risk of sandbox kill
# Risks: xpcproxyhook may check if target is symlink (unlikely), posix_spawn may re-resolve
# differently than access() (possible edge case)
#
# This is a fallback IF deploy_nanoregistryd_v2.sh (re-sign approach) fails.

set +e

SYSBIN=/var/jb/System/Library/SysBins/nanoregistryd
ORIG=/usr/libexec/nanoregistryd

echo
echo "================ STEP 0: sanity ================"
[ -x "$ORIG" ] || { echo "ERROR: $ORIG missing"; exit 1; }
echo "Original binary: $(ls -la $ORIG)"

echo
echo "================ STEP 1: cleanup ================"
rm -f /var/mobile/Library/Logs/CrashReporter/nanoregistryd-*.ips 2>/dev/null
rm -f /var/tmp/wp11_nanoregistryd.txt 2>/dev/null
rm -f "$SYSBIN" 2>/dev/null
killall -9 nanoregistryd 2>/dev/null
sleep 1

echo
echo "================ STEP 2: create symlink ================"
mkdir -p "$(dirname "$SYSBIN")"
ln -sf "$ORIG" "$SYSBIN"
ls -la "$SYSBIN"
echo "readlink: $(readlink $SYSBIN)"

echo
echo "================ STEP 3: verify bindfs exposure ================"
ls -la /System/Library/VideoCodecs/SysBins/nanoregistryd 2>&1
echo "readlink from bindfs: $(readlink /System/Library/VideoCodecs/SysBins/nanoregistryd 2>&1)"
# Important: the access() check in xpcproxyhook follows symlinks, so this should show as existing

echo
echo "================ STEP 4: test access (what xpcproxyhook sees) ================"
if [ -e /System/Library/VideoCodecs/SysBins/nanoregistryd ]; then
    echo "✅ access(F_OK) would succeed"
else
    echo "❌ access would fail — xpcproxyhook won't trigger DYLD_INSERT"
fi

echo
echo "================ STEP 5: trigger spawn ================"
launchctl kickstart -k gui/501/com.apple.nanoregistryd 2>&1
sleep 4

echo
echo "================ STEP 6: process status ================"
PIDS=$(pgrep -f nanoregistryd 2>/dev/null || ps -axo pid,command | grep -v grep | grep nanoregistryd | awk '{print $1}')
if [ -n "$PIDS" ]; then
    echo "✅ Running PIDs: $PIDS"
    for pid in $PIDS; do
        ps -p $pid -o pid,command 2>&1
    done
else
    echo "❌ No nanoregistryd running"
fi

echo
echo "================ STEP 7: witness file ================"
if [ -f /var/tmp/wp11_nanoregistryd.txt ]; then
    echo "✅✅✅ WITNESS FOUND — tweak loaded via SYMLINK approach! ✅✅✅"
    ls -la /var/tmp/wp11_nanoregistryd.txt
    echo "--- log entries ---"
    grep nanoregistryd /var/tmp/wp11.log 2>&1 | tail -20
else
    echo "❌ No witness file"
fi

echo
echo "================ STEP 8: crash check ================"
NEW=$(ls -t /var/mobile/Library/Logs/CrashReporter/nanoregistryd-*.ips 2>/dev/null | head -2)
if [ -z "$NEW" ]; then
    echo "✅ No crashes"
else
    echo "❌ CRASHES:"
    echo "$NEW"
    LATEST=$(echo "$NEW" | head -1)
    grep -E "termination|exception|procPath" "$LATEST" | head -5
fi

echo
echo "================ DIAGNOSTIC: who called nanoregistryd ================"
# If xpcproxyhook did its job, the process should have DYLD_INSERT_LIBRARIES in env
# We can't read another proc's env on iOS directly, but log /var/tmp/wp11.log should show
grep -i nanoreg /var/tmp/wp11.log 2>&1 | head -5

echo
echo "================ DONE ================"
