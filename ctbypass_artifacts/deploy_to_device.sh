#!/bin/bash
# Deploy CT-bypass-signed apsd/ids/appconduitd to device
# Prerequisites: iPhone connected via USB, usbipd attached, iproxy 8022 running, sshd up
set -e

PERSIST=/home/plokijuter/legizmo/watchos26-tweak/ctbypass_artifacts
SSH_PORT=8022
PASS=123Vde6jqh8
IFUSE_MOUNT=/tmp/imount_deploy

echo "=== 1/6 — Verify SSH + iPhone reachable ==="
if ! sshpass -p "$PASS" ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 mobile@127.0.0.1 'echo OK' >/dev/null 2>&1; then
  echo "ERROR: SSH not reachable on port $SSH_PORT. Setup iproxy + USB first."
  exit 1
fi

echo "=== 2/6 — Upload signed binaries via AFC (3 files, ~14MB total) ==="
mkdir -p $IFUSE_MOUNT
fusermount -u $IFUSE_MOUNT 2>/dev/null || true
ifuse $IFUSE_MOUNT
cp -v $PERSIST/apsd $IFUSE_MOUNT/Downloads/wp11_apsd_signed
cp -v $PERSIST/identityservicesd $IFUSE_MOUNT/Downloads/wp11_ids_signed
cp -v $PERSIST/appconduitd $IFUSE_MOUNT/Downloads/wp11_apc_signed
ls -la $IFUSE_MOUNT/Downloads/wp11_*_signed
fusermount -u $IFUSE_MOUNT

echo "=== 3/6 — Install nested SysBins twins ==="
sshpass -p "$PASS" ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@127.0.0.1 "
echo '$PASS' | sudo -S mkdir -p /var/jb/System/Library/SysBins/ApplePushService.framework /var/jb/System/Library/SysBins/IDS.framework/identityservicesd.app /var/jb/System/Library/SysBins/AppConduit.framework/Support

echo '$PASS' | sudo -S cp /var/mobile/Media/Downloads/wp11_apsd_signed /var/jb/System/Library/SysBins/ApplePushService.framework/apsd
echo '$PASS' | sudo -S cp /var/mobile/Media/Downloads/wp11_ids_signed /var/jb/System/Library/SysBins/IDS.framework/identityservicesd.app/identityservicesd
echo '$PASS' | sudo -S cp /var/mobile/Media/Downloads/wp11_apc_signed /var/jb/System/Library/SysBins/AppConduit.framework/Support/appconduitd

echo '$PASS' | sudo -S chmod +x \
  /var/jb/System/Library/SysBins/ApplePushService.framework/apsd \
  /var/jb/System/Library/SysBins/IDS.framework/identityservicesd.app/identityservicesd \
  /var/jb/System/Library/SysBins/AppConduit.framework/Support/appconduitd

echo 'Files in place:'
ls -la /var/jb/System/Library/SysBins/ApplePushService.framework/apsd /var/jb/System/Library/SysBins/IDS.framework/identityservicesd.app/identityservicesd /var/jb/System/Library/SysBins/AppConduit.framework/Support/appconduitd
"

echo "=== 4/6 — Clear log + witness files ==="
sshpass -p "$PASS" ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@127.0.0.1 "
echo '$PASS' | sudo -S rm -f /var/tmp/wp11_apsd.txt /var/tmp/wp11_identityservicesd.txt /var/tmp/wp11_appconduitd.txt
"

echo "=== 5/6 — Kill daemons → launchd respawn via SysBins ==="
sshpass -p "$PASS" ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@127.0.0.1 "
echo '$PASS' | sudo -S killall -9 apsd identityservicesd appconduitd 2>&1 || true
sleep 4
echo '=== New daemon state ==='
for d in apsd identityservicesd appconduitd; do
  PID=\$(launchctl list 2>&1 | grep com.apple.\$d | cut -f1)
  PROC=\$([ -n \"\$PID\" ] && [ \"\$PID\" != \"-\" ] && echo '$PASS' | sudo -S ps -o command= -p \$PID 2>/dev/null | tr -d '\\r' | tail -1)
  printf '%-22s pid=%-6s path=%s\\n' \"\$d\" \"\$PID\" \"\$PROC\"
done
"

echo "=== 6/6 — Verify WP11 tweak is loaded in new daemons ==="
sshpass -p "$PASS" ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@127.0.0.1 "
sleep 2
echo '--- witnesses ---'
ls -la /var/tmp/wp11_apsd.txt /var/tmp/wp11_identityservicesd.txt /var/tmp/wp11_appconduitd.txt 2>&1 | head
echo '--- log lines for new processes ---'
echo '$PASS' | sudo -S grep -oE '\[(apsd|identityservicesd|appconduitd)\]' /var/tmp/wp11.log 2>&1 | sort -u | head
"

echo "=== Deploy complete ==="
