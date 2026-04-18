#!/bin/bash
# Rollback: remove nested SysBins twins → launchd respawns daemons from original PrivateFrameworks paths
set -e

SSH_PORT=8022
PASS=123Vde6jqh8

echo "=== Removing nested SysBins ==="
sshpass -p "$PASS" ssh -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@127.0.0.1 "
echo '$PASS' | sudo -S rm -rf \
  /var/jb/System/Library/SysBins/ApplePushService.framework \
  /var/jb/System/Library/SysBins/IDS.framework \
  /var/jb/System/Library/SysBins/AppConduit.framework

echo '=== Kick daemons back to originals ==='
for d in apsd identityservicesd appconduitd; do
  echo '$PASS' | sudo -S launchctl kickstart -kp user/501/com.apple.\$d 2>&1 | tail -1
done
sleep 3
echo '=== After rollback ==='
for d in apsd identityservicesd appconduitd; do
  PID=\$(launchctl list 2>&1 | grep com.apple.\$d | cut -f1)
  PROC=\$([ -n \"\$PID\" ] && [ \"\$PID\" != \"-\" ] && echo '$PASS' | sudo -S ps -o command= -p \$PID 2>/dev/null | tr -d '\\r' | tail -1)
  printf '%-22s pid=%-6s path=%s\\n' \"\$d\" \"\$PID\" \"\$PROC\"
done
"
echo "=== Rollback done ==="
