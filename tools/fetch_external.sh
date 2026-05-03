#!/bin/bash
# Fetch the iOS static libraries needed to build tools/ct_bypass_ios.
# Run once before `make -C tools/ct_bypass_ios THEOS=$HOME/theos`.
#
# These libraries (libcrypto.a, libssl.a) are part of ChOma upstream
# (opa334/ChOma external/ios/) and total ~47 MB. They are gitignored to
# keep the WatchPair11 source repo small (the .deb itself only ships the
# stripped, signed ct_bypass_ios binary, not these .a files).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$SCRIPT_DIR/ct_bypass_ios/external/ios"
TMPDIR="$(mktemp -d)"
trap "rm -rf $TMPDIR" EXIT

mkdir -p "$TARGET_DIR"

if [ -f "$TARGET_DIR/libcrypto.a" ] && [ -f "$TARGET_DIR/libssl.a" ]; then
  echo "[fetch] iOS libcrypto/libssl already present in $TARGET_DIR — skipping"
  exit 0
fi

echo "[fetch] Cloning ChOma to retrieve external/ios libs..."
git clone --depth=1 https://github.com/opa334/ChOma.git "$TMPDIR/ChOma"

cp -v "$TMPDIR/ChOma/external/ios/libcrypto.a" "$TARGET_DIR/"
cp -v "$TMPDIR/ChOma/external/ios/libssl.a" "$TARGET_DIR/"

# Stage host OpenSSL headers (used by coretrust_bug.c). The host needs
# openssl-dev installed (Debian/Ubuntu : `sudo apt install libssl-dev`).
INC_DIR="$SCRIPT_DIR/ct_bypass_ios/external/include"
if [ ! -d "$INC_DIR/openssl" ]; then
  if [ -d /usr/include/openssl ]; then
    echo "[fetch] Staging host /usr/include/openssl headers..."
    mkdir -p "$INC_DIR"
    cp -r /usr/include/openssl "$INC_DIR/openssl"
    # opensslconf.h + configuration.h live in arch-specific dir on Debian
    for h in opensslconf.h configuration.h; do
      ARCH_HDR=$(find /usr/include -name "$h" -path "*openssl*" 2>/dev/null | head -1)
      [ -n "$ARCH_HDR" ] && cp "$ARCH_HDR" "$INC_DIR/openssl/"
    done
  else
    echo "[fetch] WARN : /usr/include/openssl not found." >&2
    echo "        Install libssl-dev (apt) or openssl-devel (rpm) and rerun." >&2
  fi
fi

echo ""
echo "[fetch] Done. Now build with :"
echo "  make -C tools/ct_bypass_ios THEOS=\$HOME/theos"
