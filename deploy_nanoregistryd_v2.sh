#!/bin/bash
# Deploy script v2 for nanoregistryd SysBins injection
#
# KEY FIX vs previous attempts:
#   1. Uses `-M` (merge) flag on ldid to preserve ORIGINAL restricted
#      entitlements (like platform-application) from the Apple-signed
#      nanoregistryd binary, instead of replacing them with our xml.
#   2. XML file now contains ONLY exception entitlements + get-task-allow
#      in the nathanlr format (mirrors bluetoothd.xml / cfprefsd.xml pattern).
#   3. ct_bypass invocation matches nathanlr's apply_coretrust_bypass_wrapper
#      semantics (input == output, in-place via -r).
#
# The script also does a side-by-side comparison with bluetoothd (which works)
# to show WHERE our signature/trust differs, for diagnosis if the -M fix alone
# isn't enough.
#
# Prerequisites on device:
#   - /var/jb/basebins/ldid_dpkg_autosign exists
#   - /var/jb/usr/bin/ct_bypass exists
#   - WatchPair26 v6.5 is installed with bluetoothd in filter
#   - Entitlements xml uploaded to /var/jb/basebins/entitlements/nanoregistryd.xml

set +e  # Don't exit on individual errors, we want diagnostics

SYSBIN=/var/jb/System/Library/SysBins/nanoregistryd
ORIG=/usr/libexec/nanoregistryd
ENT_XML=/var/jb/basebins/entitlements/nanoregistryd.xml
LDID=/var/jb/basebins/ldid_dpkg_autosign
CTBP=/var/jb/usr/bin/ct_bypass

BT=/var/jb/System/Library/SysBins/bluetoothd  # reference (working)

echo
echo "================ STEP 0: sanity checks ================"
for f in "$LDID" "$CTBP" "$ORIG"; do
    if [ ! -e "$f" ]; then echo "ERROR: missing $f"; exit 1; fi
done
if [ ! -f "$ENT_XML" ]; then
    echo "ERROR: entitlements file missing at $ENT_XML"
    echo "       scp it first via WSL"
    exit 1
fi
echo "All prerequisites present."

echo
echo "================ STEP 1: cleanup previous state ================"
rm -f /var/mobile/Library/Logs/CrashReporter/nanoregistryd-*.ips 2>/dev/null
rm -f /var/tmp/wp26_nanoregistryd.txt 2>/dev/null
rm -f "$SYSBIN" 2>/dev/null
# Kill existing instance if any
killall -9 nanoregistryd 2>/dev/null
sleep 1

echo
echo "================ STEP 2: copy nanoregistryd to SysBins ================"
mkdir -p "$(dirname "$SYSBIN")"
cp "$ORIG" "$SYSBIN"
chmod +x "$SYSBIN"
ls -la "$SYSBIN"

echo
echo "================ STEP 3: ldid -M MERGE entitlements ================"
# -M merges xml entitlements with existing binary entitlements
# (preserves platform-application and other restricted ents from original)
"$LDID" -M "-S$ENT_XML" "-Icom.apple.nanoregistryd" "$SYSBIN"
LDID_RC=$?
echo "ldid exit: $LDID_RC"

echo
echo "================ STEP 4: ct_bypass in-place ================"
"$CTBP" -i "$SYSBIN" -o "$SYSBIN" -r 2>&1 | tail -20
CTBP_RC=$?
echo "ct_bypass exit: $CTBP_RC"
ls -la "$SYSBIN"

echo
echo "================ STEP 5: verify our signature ================"
echo "--- OUR nanoregistryd ---"
"$LDID" -h "$SYSBIN" 2>&1 | head -20
echo "--- OUR entitlements (truncated) ---"
"$LDID" -e "$SYSBIN" 2>&1 | head -30

if [ -f "$BT" ]; then
    echo
    echo "--- REFERENCE: working bluetoothd signature ---"
    "$LDID" -h "$BT" 2>&1 | head -20
    echo "--- REFERENCE: bluetoothd entitlements (truncated) ---"
    "$LDID" -e "$BT" 2>&1 | head -30
fi

echo
echo "================ STEP 6: verify bindfs exposure ================"
ls -la /System/Library/VideoCodecs/SysBins/nanoregistryd 2>&1 | head -3

echo
echo "================ STEP 7: trigger respawn ================"
launchctl kickstart -k gui/501/com.apple.nanoregistryd 2>&1
sleep 4

echo
echo "================ STEP 8: process status ================"
ps -axo pid,command | grep -i nanoreg | grep -v grep
if [ $? -eq 0 ]; then
    echo "✅ PROCESS IS RUNNING"
else
    echo "❌ no nanoregistryd process (lazy launched, may need client trigger)"
fi

echo
echo "================ STEP 9: witness file ================"
if [ -f /var/tmp/wp26_nanoregistryd.txt ]; then
    echo "✅✅✅ WITNESS FOUND — tweak loaded into nanoregistryd! ✅✅✅"
    ls -la /var/tmp/wp26_nanoregistryd.txt
    echo "--- nanoregistryd entries in wp26.log ---"
    grep nanoregistryd /var/tmp/wp26.log 2>&1 | tail -20
else
    echo "❌ No witness file"
fi

echo
echo "================ STEP 10: crash check ================"
NEW_CRASHES=$(ls -t /var/mobile/Library/Logs/CrashReporter/nanoregistryd-*.ips 2>/dev/null | head -3)
if [ -z "$NEW_CRASHES" ]; then
    echo "✅ NO new crashes"
else
    echo "❌ CRASHES detected:"
    echo "$NEW_CRASHES"
    echo
    echo "--- latest crash diagnostic fields ---"
    LATEST=$(ls -t /var/mobile/Library/Logs/CrashReporter/nanoregistryd-*.ips 2>/dev/null | head -1)
    grep -E "termination|codeSigning|exception|procPath|procExit" "$LATEST" 2>/dev/null | head -15
    echo
    echo "--- reportNotes ---"
    grep -A 0 "reportNotes" "$LATEST" 2>/dev/null
    grep -E "dyld|sandbox|amfi|trust" "$LATEST" 2>/dev/null | head -10
fi

echo
echo "================ CLEANUP ON FAILURE ================"
# If it crashed, remove the SysBin to stop the respawn loop
if [ -n "$NEW_CRASHES" ]; then
    echo "Removing $SYSBIN to stop crash loop..."
    rm -f "$SYSBIN"
    echo "You can re-run this script after fixing the issue."
fi

echo
echo "================ DONE ================"
