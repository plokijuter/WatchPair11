#!/bin/bash
# Pipeline: patch arm64e→arm64 + ldid-sign + ct_bypass → ready to deploy
set -e

if [ $# -lt 2 ]; then
  echo "Usage: $0 <daemon_name> <original_binary_path>"
  echo "  Where daemon_name: apsd, identityservicesd, appconduitd"
  echo "  Writes to /tmp/ts_build/signed/<daemon_name>"
  exit 1
fi

NAME=$1
INPUT=$2
OUT_DIR=/tmp/ts_build/signed
mkdir -p $OUT_DIR

OUT=$OUT_DIR/$NAME
CT_BYPASS=/tmp/ts_build/out/ct_bypass_linux
LDID=/home/plokijuter/theos/toolchain/linux/iphone/bin/ldid

# Entitlement files (pre-prepared in /tmp/ts_build/)
case $NAME in
  apsd)
    ENTS=/tmp/ts_build/apsd_final_ents.xml
    IDENT=com.apple.apsd
    ;;
  identityservicesd|ids)
    ENTS=/tmp/ts_build/ids_final_ents.xml
    IDENT=com.apple.identityservicesd
    NAME=identityservicesd
    ;;
  appconduitd|apc)
    ENTS=/tmp/ts_build/apc_final_ents.xml
    IDENT=com.apple.appconduitd
    NAME=appconduitd
    ;;
  *)
    echo "Unknown daemon: $NAME"; exit 1 ;;
esac

if [ ! -f "$ENTS" ]; then
  echo "Missing ents: $ENTS (run prep_ents.py first and make sure original ents are dumped on device)"
  exit 1
fi

echo "=== Step 1: Copy original binary ==="
cp -f "$INPUT" "$OUT"
chmod +x "$OUT"

echo "=== Step 2: Patch arm64e→arm64 (byte at offset 8) ==="
# Check if already patched
head -c 12 "$OUT" | tail -c 4 | od -An -tx1 | tr -d ' '
printf '\x00\x00\x00\x00' | dd of="$OUT" bs=1 seek=8 count=4 conv=notrunc 2>&1 | tail -1

echo "=== Step 3: ldid sign with entitlements ==="
$LDID -S"$ENTS" -I"$IDENT" "$OUT"

echo "=== Step 4: ct_bypass ==="
$CT_BYPASS "$OUT"

echo "=== Step 5: Verify ==="
$LDID -h "$OUT" 2>&1 | grep -E "Identifier=|CDHash=|TeamIdentifier=|flags=" | head

echo "=== Done: $OUT ==="
ls -la "$OUT"
