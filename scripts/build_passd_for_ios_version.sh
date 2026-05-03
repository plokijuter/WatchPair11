#!/bin/bash
# WatchPair11 — Multi-iOS passd build pipeline
# =============================================================================
# Takes an unmodified `passd` Mach-O binary extracted from any iOS version's
# dyld_shared_cache (PassKitCore.framework/passd) and produces a signed,
# CoreTrust-bypassed `passd_signed_<build>.bin` ready to be shipped in the
# WatchPair11 .deb (under layout/opt/watchpair11/).
#
# Pipeline steps (all mechanical, no logic patches):
#   1. Sanity-check input is a thin or fat arm64/arm64e Mach-O
#   2. Backup the original
#   3. Patch the cpusubtype byte (arm64e -> arm64) at offset +8 of the
#      arm64e slice header. This satisfies CoreTrust CPU subtype validation.
#   4. ldid-sign with passd_ents.xml (preserves Apple-restricted entitlements)
#   5. Apply CoreTrust bypass (CVE-2023-41991) via ct_bypass_linux
#   6. Verify output (size, signature, basic strings)
#   7. Emit `passd_signed_<build>.bin` in the output dir
#
# IMPORTANT — see docs-internal/passd-patches-audit.md for why this works:
# all 7 logic bypasses are runtime hooks (Tweak.xm). The pre-signed binary
# only carries the arm64e->arm64 architecture conversion. Therefore one
# pipeline script is sufficient to support every iOS build.
#
# Usage:
#   bash scripts/build_passd_for_ios_version.sh <input_passd> <build_id> [out_dir]
# Example:
#   bash scripts/build_passd_for_ios_version.sh /tmp/passd_orig 20G75
#   bash scripts/build_passd_for_ios_version.sh /tmp/passd_iOS17 21E236 layout/opt/watchpair11
# =============================================================================

set -euo pipefail

# --- Args / defaults ---------------------------------------------------------

if [ $# -lt 2 ]; then
  cat <<EOF
Usage: $0 <input_passd_path> <ios_build_id> [output_dir]

Arguments:
  input_passd_path   Absolute path to an unmodified \`passd\` Mach-O binary
                     (extracted from /System/Library/PrivateFrameworks/
                     PassKitCore.framework/passd of the target iOS dyld
                     shared cache).
  ios_build_id       Apple iOS build identifier (e.g. 20G75, 21E236).
                     This becomes the suffix on the output file:
                     passd_signed_<build>.bin
  output_dir         Where to write the signed binary.
                     Default: layout/opt/watchpair11/

Examples:
  $0 /tmp/passd_extracted 20G75
  $0 /tmp/passd_iOS17 21E236 layout/opt/watchpair11

See docs-internal/MULTI_IOS_BUILD.md for end-to-end instructions
(extracting passd from a dyld_shared_cache, packaging the .deb, etc).
EOF
  exit 1
fi

INPUT="$1"
BUILD_ID="$2"
OUT_DIR="${3:-layout/opt/watchpair11}"

# Resolve script-relative paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Tools — search a few standard locations for ct_bypass_linux.
# Override with CT_BYPASS=/path env var.
if [ -z "${CT_BYPASS:-}" ]; then
  for cand in \
      "$REPO_ROOT/ctbypass_artifacts/ct_bypass_linux" \
      "/tmp/ts_build/out/ct_bypass_linux"; do
    if [ -x "$cand" ]; then CT_BYPASS="$cand"; break; fi
  done
fi
LDID="${LDID:-$HOME/theos/toolchain/linux/iphone/bin/ldid}"
ENTS_XML="${ENTS_XML:-$REPO_ROOT/layout/opt/watchpair11/passd_ents.xml}"
PASSD_IDENT="com.apple.passd"

# Resolve OUT_DIR relative to repo root if not absolute
case "$OUT_DIR" in
  /*) ;;
  *) OUT_DIR="$REPO_ROOT/$OUT_DIR" ;;
esac

# --- Colors / helpers --------------------------------------------------------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'; N='\033[0m'
log()  { echo -e "${C}[BUILD]${N} $1"; }
ok()   { echo -e "${G}[OK]${N}    $1"; }
warn() { echo -e "${Y}[WARN]${N}  $1"; }
err()  { echo -e "${R}[ERR]${N}   $1" >&2; }

die() { err "$1"; exit 1; }

# --- Step 0 : sanity check tooling ------------------------------------------

log "Multi-iOS passd build pipeline (target build $BUILD_ID)"
echo ""

[ -f "$INPUT" ] || die "Input binary not found: $INPUT"
[ -x "$CT_BYPASS" ] || die "ct_bypass_linux not found or not executable at $CT_BYPASS
  Build it via: cd ctbypass_artifacts && bash build_linux_ctbp.sh"
[ -x "$LDID" ] || die "ldid not found at $LDID  (override with LDID=/path/to/ldid)"
[ -f "$ENTS_XML" ] || die "Entitlements XML not found: $ENTS_XML"

mkdir -p "$OUT_DIR"

OUTPUT="$OUT_DIR/passd_signed_${BUILD_ID}.bin"

# Idempotency: if output already exists, back it up first
if [ -f "$OUTPUT" ]; then
  warn "Output exists, will overwrite: $OUTPUT"
  cp -f "$OUTPUT" "${OUTPUT}.prev"
  ok "Previous output backed up to ${OUTPUT}.prev"
fi

# --- Step 1 : sanity-check input is a Mach-O --------------------------------

log "Step 1/6 — Validating input Mach-O"

# Read first 4 bytes
MAGIC=$(head -c 4 "$INPUT" | od -An -tx1 | tr -d ' \n')
case "$MAGIC" in
  cffaedfe|cefaedfe)
    KIND="thin64"
    ok "Thin Mach-O 64-bit detected (magic=$MAGIC)"
    ;;
  cafebabe|bebafeca|cafebabf|bfbafeca)
    KIND="fat"
    ok "Fat Mach-O detected (magic=$MAGIC)"
    ;;
  *)
    die "Not a Mach-O binary (unknown magic: $MAGIC)
  Expected one of: cffaedfe (Mach-O 64 LE), cafebabe (fat), cafebabf (fat64)"
    ;;
esac

INPUT_SIZE=$(stat -c%s "$INPUT")
INPUT_SHA=$(sha256sum "$INPUT" | awk '{print $1}')
log "  Input size : $INPUT_SIZE bytes"
log "  Input SHA  : $INPUT_SHA"
echo ""

# --- Step 2 : copy + backup + arm64e->arm64 patch ---------------------------

log "Step 2/6 — Copying input + applying arm64e -> arm64 cpusubtype patch"

# Stage to a temp working file first (idempotent: the input is never touched)
WORK="${OUTPUT}.work"
cp -f "$INPUT" "$WORK"
chmod +x "$WORK"

# Patch the cpusubtype field (offset +8 of the arm64e Mach-O header).
# Mach-O 64 header layout:
#   off 0..3   magic       (cffaedfe)
#   off 4..7   cputype     (0c000001 = arm64 LE = 0x0100000c)
#   off 8..11  cpusubtype  (00000080 = arm64e LE)  -> patch to (00000000 = arm64_ALL)
#   off 12..15 filetype
#
# For fat binaries, the per-arch slice header layout (fat_arch_64 if cafebabf):
#   We only need the thin slice case here (Apple ships passd as thin64 in dyld
#   cache extracts). If you have a fat binary, extract the arm64e slice first
#   with ChOma's `chomatool` or `lipo -thin arm64e <fat> -output passd`.
# The existing project uses thin64 binaries (see ctbypass_artifacts/main_linux.c
# extract_preferred_slice — it picks the preferred slice and writes it out
# thin). Therefore we enforce thin64 input here.

if [ "$KIND" = "fat" ]; then
  warn "Fat binary detected. We only support thin Mach-O input."
  warn "Please extract the arm64e (or arm64) slice first, e.g.:"
  warn "  lipo -thin arm64e $INPUT -output ${INPUT}.thin"
  warn "Then re-run with: $0 ${INPUT}.thin $BUILD_ID"
  rm -f "$WORK"
  exit 1
fi

# Read current cpusubtype byte 8 (LE: byte order, the high bit of cpusubtype)
SUBTYPE_BYTES=$(head -c 12 "$WORK" | tail -c 4 | od -An -tx1 | tr -d ' ')
log "  Current cpusubtype bytes (offset +8..11): $SUBTYPE_BYTES"

case "$SUBTYPE_BYTES" in
  00000080)
    log "  Patching arm64e (subtype 0x80) -> arm64_ALL (subtype 0x00)"
    # Write 4 zero bytes at offset 8
    printf '\x00\x00\x00\x00' | dd of="$WORK" bs=1 seek=8 count=4 conv=notrunc status=none
    ok "  cpusubtype patched"
    ;;
  00000000)
    warn "  Already arm64_ALL (no patch needed). Continuing — pipeline is idempotent."
    ;;
  00000001)
    warn "  arm64_v8 detected. No patch needed (already non-arm64e)."
    ;;
  *)
    warn "  Unexpected cpusubtype $SUBTYPE_BYTES — proceeding anyway"
    ;;
esac
echo ""

# --- Step 3 : ldid-sign with restricted entitlements ------------------------

log "Step 3/6 — ldid-sign with restricted entitlements"

# We use -S (sign) with the entitlements XML.
# (Note: the audit shipped binary used a different signing flow, but the net
#  result here is the same — ldid stages the entitlements, ct_bypass then
#  fixes up the CMS blob to satisfy CoreTrust.)
"$LDID" -S"$ENTS_XML" -I"$PASSD_IDENT" "$WORK"
ok "Signed with entitlements ($(wc -l < "$ENTS_XML") line plist) and identifier $PASSD_IDENT"
echo ""

# --- Step 4 : ct_bypass ------------------------------------------------------

log "Step 4/6 — Applying CoreTrust bypass (CVE-2023-41991)"
"$CT_BYPASS" "$WORK"
ok "CoreTrust bypass applied"
echo ""

# --- Step 5 : verify ---------------------------------------------------------

log "Step 5/6 — Verifying output"

OUT_SIZE=$(stat -c%s "$WORK")
OUT_SHA=$(sha256sum "$WORK" | awk '{print $1}')

# Basic Mach-O re-validate
NEW_MAGIC=$(head -c 4 "$WORK" | od -An -tx1 | tr -d ' \n')
[ "$NEW_MAGIC" = "cffaedfe" ] || die "Output magic corrupted ($NEW_MAGIC), aborting"
ok "  Output Mach-O magic OK ($NEW_MAGIC)"

# Confirm signature blob is present (LC_CODE_SIGNATURE = 0x1d = 29)
# A simple proxy: check that ldid -h reports a code signature
if "$LDID" -h "$WORK" 2>/dev/null | grep -qi "CDHash\|Identifier\|TeamIdentifier"; then
  IDENT_LINE=$("$LDID" -h "$WORK" 2>/dev/null | grep -E "Identifier=|TeamIdentifier=" | head -2 | tr '\n' ' ')
  ok "  Code signature present: $IDENT_LINE"
else
  warn "  ldid -h didn't report typical signature fields — check manually"
fi

# Sanity: a couple of strings we expect in any passd. Use -a to scan the
# whole file (signature blobs can sit beyond the default scan window).
if strings -a "$WORK" 2>/dev/null | grep -qE "PassKitCore|com\.apple\.passd"; then
  ok "  Strings sanity check passed (found PassKit markers)"
else
  warn "  PassKit markers not found — binary may be truncated/corrupted"
fi

log "  Output size : $OUT_SIZE bytes"
log "  Output SHA  : $OUT_SHA"
echo ""

# --- Step 6 : finalize -------------------------------------------------------

log "Step 6/6 — Finalizing output"
mv -f "$WORK" "$OUTPUT"
chmod 755 "$OUTPUT"
ok "Wrote $OUTPUT"
echo ""

# --- Summary -----------------------------------------------------------------

log "=============================================="
log "Build complete for iOS build $BUILD_ID"
log "=============================================="
echo "  Input  : $INPUT"
echo "    size : $INPUT_SIZE bytes"
echo "    sha  : $INPUT_SHA"
echo ""
echo "  Output : $OUTPUT"
echo "    size : $OUT_SIZE bytes"
echo "    sha  : $OUT_SHA"
echo ""
echo "Next steps:"
echo "  1. (Optional) git add $OUTPUT"
echo "  2. Rebuild the .deb : make package FINALPACKAGE=1 THEOS=\$HOME/theos"
echo "  3. The .deb will pick up passd_signed_${BUILD_ID}.bin automatically"
echo "  4. setup-applepay.sh on devices running build $BUILD_ID will use it"
echo ""
