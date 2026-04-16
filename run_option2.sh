#!/bin/bash
# Orchestrator script — run from WSL, handles USB reconnection, transfer, and deploy
#
# Prerequisites:
#   - iPhone plugged in and jailbroken with nathanlr
#   - USBPcap desinstallé (ou bien app "Périphériques Apple" stoppée)
#   - usbipd bind 2-6 attachable
#
# Usage:
#   ./run_option2.sh          # Plan A (re-sign with -M)
#   ./run_option2.sh symlink  # Plan B (symlink approach)

MODE="${1:-resign}"

if [ "$MODE" = "symlink" ]; then
    DEPLOY_SCRIPT=/home/plokijuter/legizmo/watchos26-tweak/deploy_nanoregistryd_symlink.sh
    DEPLOY_NAME="SYMLINK (Plan B)"
else
    DEPLOY_SCRIPT=/home/plokijuter/legizmo/watchos26-tweak/deploy_nanoregistryd_v2.sh
    DEPLOY_NAME="RE-SIGN with -M flag (Plan A)"
fi

ENT_XML=/home/plokijuter/legizmo/watchos26-tweak/nanoregistryd.xml
SSHPASS="${IPHONE_SSHPASS:?Set IPHONE_SSHPASS env var}"
IPHONE="sshpass -p $SSHPASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 iphone"

echo "=============================================="
echo " OPTION 2 — $DEPLOY_NAME"
echo "=============================================="

echo
echo "[0/6] Verify iPhone USB connection..."
idevice_id -l 2>&1 | head -1
if ! idevice_id -l 2>&1 | grep -q "00008120"; then
    echo "iPhone not detected in usbmuxd. Attempting usbmuxd restart..."
    sudo pkill -9 usbmuxd 2>/dev/null
    sleep 1
    sudo usbmuxd
    sleep 3
    idevice_id -l 2>&1 | head -1
fi

echo
echo "[1/6] Ensure iproxy forwarding..."
if ! pgrep -f "iproxy 2222" >/dev/null; then
    iproxy 2222 22 > /tmp/iproxy.log 2>&1 &
    disown $! 2>/dev/null
    sleep 2
fi

echo
echo "[2/6] Test SSH..."
if ! $IPHONE "echo alive" 2>&1 | grep -q alive; then
    echo "ERROR: SSH down. Reconnect iPhone, unlock it, and re-run."
    exit 1
fi
echo "SSH OK"

echo
echo "[3/6] Transfer entitlements xml..."
sshpass -p "$SSHPASS" scp -P 2222 -o StrictHostKeyChecking=no "$ENT_XML" mobile@127.0.0.1:/tmp/nanoregistryd.xml
$IPHONE "echo $SSHPASS | sudo -S cp /tmp/nanoregistryd.xml /var/jb/basebins/entitlements/nanoregistryd.xml && sudo ls -la /var/jb/basebins/entitlements/nanoregistryd.xml"

echo
echo "[4/6] Transfer deploy script..."
sshpass -p "$SSHPASS" scp -P 2222 -o StrictHostKeyChecking=no "$DEPLOY_SCRIPT" mobile@127.0.0.1:/tmp/deploy_nano.sh
$IPHONE "chmod +x /tmp/deploy_nano.sh && ls -la /tmp/deploy_nano.sh"

echo
echo "[5/6] Execute deploy script as root..."
$IPHONE "echo $SSHPASS | sudo -S /tmp/deploy_nano.sh 2>&1"

echo
echo "[6/6] Summary."
echo "If witness file appeared, option 2 worked! You can proceed to EPDevice hooks."
echo "If crashes, try: ./run_option2.sh symlink (plan B)"
