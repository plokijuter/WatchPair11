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

echo ""
echo "[fetch] Done. Now build with :"
echo "  make -C tools/ct_bypass_ios THEOS=\$HOME/theos"
