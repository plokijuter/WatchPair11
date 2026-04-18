#!/bin/bash
set -e
cd /tmp/ts_build

TS=TrollStore_patched
FPS=$TS/Exploits/fastPathSign
CHOMA=$TS/ChOma/src

OUT=/tmp/ts_build/out
mkdir -p $OUT

# ChOma C sources (skip tests and cli)
CHOMA_SOURCES=$(ls $CHOMA/*.c 2>/dev/null | grep -v "/tests/" | grep -v "/cli/")
CT_SOURCES="$FPS/src/coretrust_bug.c $FPS/src/main_linux.c"

CFLAGS="-I$CHOMA \
-I$FPS/src \
-I/tmp/ts_build/compat_headers \
-DUSE_LIBPLIST \
-fblocks \
-include stdint.h \
-include stddef.h \
-Wno-pointer-to-int-cast \
-Wno-unused-command-line-argument \
-Wno-deprecated-declarations \
-Wno-format \
-Wno-implicit-function-declaration \
-Wno-int-conversion \
-Wno-incompatible-pointer-types \
-Wno-macro-redefined"

echo "=== Building ct_bypass for Linux x86_64 (with libplist) ==="
clang $CFLAGS \
  $CHOMA_SOURCES \
  $CT_SOURCES \
  -lcrypto -lplist-2.0 -lBlocksRuntime -lm \
  -o $OUT/ct_bypass_linux > /tmp/ctbp_build.log 2>&1
RC=$?
echo "compile RC=$RC"
grep -cE "error:" /tmp/ctbp_build.log | head -1
echo "--- errors only ---"
grep -E "error:|undefined reference" /tmp/ctbp_build.log | head -30

echo ""
echo "=== Result ==="
ls -la $OUT/ct_bypass_linux 2>&1 || echo "build FAILED"
file $OUT/ct_bypass_linux 2>&1 || true
