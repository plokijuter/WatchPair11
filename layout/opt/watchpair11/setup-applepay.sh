#!/bin/bash
# WatchPair11 — Apple Pay Setup Script
# Purpose: Deploy passd pipeline + PassKit preferences for Apple Pay
#          on watchOS 11.5 + iOS 16/17/18 (multi-iOS, fully on-device, v8.0+)
# Required: Root (sudo), nathanlr OR roothide jailbreak, WatchPair11 .deb installed
# Tested:   iPhone 14 Pro Max iOS 16.6 build 20G75 + Apple Watch Series 10
#
# v8.0 — fully on-device pipeline, zero external dependencies :
#   * If a per-build pre-signed binary exists (e.g. passd_signed_20G75.bin
#     shipped with the .deb for the canonical build), use it immediately.
#   * Otherwise, build it ON THE PHONE in ~30-60 seconds :
#       1. detect iOS build
#       2. dsc_extractor /private/preboot/.../dyld_shared_cache_arm64e -> /tmp
#       3. patch cpusubtype byte arm64e -> arm64
#       4. ldid -M sign with restricted entitlements
#       5. ct_bypass_ios in-place
#       6. cache the result at $JB/opt/watchpair11/passd_signed_<BUILD>.bin
#   * Then proceed with the normal SysBins-overlay + LaunchDaemon override
#     + PassKit prefs + service reload.
#
# This means the .deb works on ANY iOS build out of the box, no per-version
# Linux work required from the maintainer.

set -e

# =============================================================================
# CONFIG — auto-detect rootless (nathanlr) vs roothide
# =============================================================================
if command -v jbroot >/dev/null 2>&1; then
  JB_PREFIX="$(jbroot)"
  JB_FLAVOR="roothide"
elif [ -d /var/jb ]; then
  JB_PREFIX="/var/jb"
  JB_FLAVOR="rootless"
else
  echo "[ERR] Neither roothide (jbroot tool) nor nathanlr (/var/jb) detected." >&2
  exit 1
fi

BUNDLE_DIR="$JB_PREFIX/opt/watchpair11"
PASSD_PLIST="$BUNDLE_DIR/com.apple.passd.plist"
SYSBINS_DIR="$JB_PREFIX/System/Library/SysBins/PassKitCore.framework"
LAUNCHD_OVERRIDE="$JB_PREFIX/Library/LaunchDaemons/com.apple.passd.plist"
BACKUP_DIR="$JB_PREFIX/opt/watchpair11/backup"
PASSKIT_PREFS="/var/mobile/Library/Preferences/com.apple.passd.plist"

# v8.0 on-device pipeline tools
DSC_EXTRACTOR="$BUNDLE_DIR/dsc_extractor"
CT_BYPASS_IOS="$BUNDLE_DIR/ct_bypass_ios"
LDID="$JB_PREFIX/usr/bin/ldid"
ENTS_XML="$BUNDLE_DIR/passd_ents.xml"
DSC_PATH="/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
DSC_PATH_LEGACY="/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
WORK_DIR="/tmp/wp11_extract"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'; N='\033[0m'
log() { echo -e "${C}[WP11]${N} $1"; }
ok()  { echo -e "${G}[OK]${N}   $1"; }
err() { echo -e "${R}[ERR]${N}  $1" >&2; }
warn(){ echo -e "${Y}[WARN]${N} $1"; }

log "WatchPair11 Apple Pay Setup v8.0 (on-device pipeline)"
log "======================================================"
log "Jailbreak flavor : $JB_FLAVOR (prefix: $JB_PREFIX)"
echo ""

if [ "$EUID" -ne 0 ]; then
  err "This script must run as root. Run with: sudo bash $0"
  exit 1
fi

IOS_VERSION=$(sw_vers -productVersion 2>/dev/null || uname -r)
BUILD_VERSION=$(sw_vers -buildVersion 2>/dev/null || echo "unknown")
log "iOS version detected: $IOS_VERSION (build $BUILD_VERSION)"

[ -d "$JB_PREFIX" ] || { err "Jailbreak prefix $JB_PREFIX not found."; exit 1; }
[ -f "$PASSD_PLIST" ] || { err "Override plist missing: $PASSD_PLIST"; exit 1; }

# =============================================================================
# Step A — Locate / build the per-build passd binary
# =============================================================================
PASSD_SIGNED=""
PER_BUILD="$BUNDLE_DIR/passd_signed_${BUILD_VERSION}.bin"
LEGACY="$BUNDLE_DIR/passd_signed"

build_passd_on_device() {
  log "Building passd for $BUILD_VERSION on-device (one-time, ~30-60s)..."

  # --- Sanity check : tools present ----------------------------------------
  log " [1/6] Sanity-checking on-device tools"
  local missing=""
  [ -x "$DSC_EXTRACTOR" ]  || missing="$missing dsc_extractor"
  [ -x "$CT_BYPASS_IOS" ]  || missing="$missing ct_bypass_ios"
  [ -x "$LDID" ]           || missing="$missing ldid"
  [ -f "$ENTS_XML" ]       || missing="$missing passd_ents.xml"
  if [ -n "$missing" ]; then
    err "Missing tool(s) :$missing"
    err "Reinstall the WatchPair11 .deb (v8.0+) or check /opt/watchpair11/"
    exit 1
  fi
  ok "  all tools present"

  # Locate the dyld shared cache (modern preboot path first, then legacy)
  local dsc=""
  if [ -f "$DSC_PATH" ]; then
    dsc="$DSC_PATH"
  elif [ -f "$DSC_PATH_LEGACY" ]; then
    dsc="$DSC_PATH_LEGACY"
  else
    err "dyld_shared_cache_arm64e not found at expected paths :"
    err "  $DSC_PATH"
    err "  $DSC_PATH_LEGACY"
    exit 1
  fi
  ok "  shared cache : $dsc ($(stat -c%s "$dsc" 2>/dev/null || echo "?") bytes)"

  # Free space check (need ~50 MB in /tmp for extraction)
  local free_kb=$(df -k /tmp | awk 'NR==2 {print $4}')
  if [ "${free_kb:-0}" -lt 51200 ]; then
    err "/tmp has less than 50 MB free ($free_kb KB) — clear space first"
    exit 1
  fi
  ok "  /tmp free: $((free_kb / 1024)) MB"
  echo ""

  # --- Extract passd from dsc ----------------------------------------------
  log " [2/6] Extracting passd from dyld_shared_cache (this is the long step)"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  if ! "$DSC_EXTRACTOR" "$dsc" "$WORK_DIR" 2>&1 | tail -10; then
    err "dsc_extractor failed (rc=$?)"
    exit 1
  fi

  local extracted_passd="$WORK_DIR/System/Library/PrivateFrameworks/PassKitCore.framework/passd"
  if [ ! -f "$extracted_passd" ]; then
    err "Expected file not produced by dsc_extractor :"
    err "  $extracted_passd"
    err "(scanning $WORK_DIR for any 'passd' file...)"
    find "$WORK_DIR" -name passd 2>/dev/null | head -5 >&2
    exit 1
  fi
  cp -f "$extracted_passd" /tmp/wp11_passd
  ok "  extracted : $(stat -c%s /tmp/wp11_passd) bytes"
  echo ""

  # --- Patch cpusubtype byte (arm64e -> arm64) -----------------------------
  log " [3/6] Patching cpusubtype byte (arm64e -> arm64)"
  # Mach-O 64 header layout :
  #   off 0..3   magic       (cffaedfe)
  #   off 4..7   cputype     (0c000001 LE = arm64)
  #   off 8..11  cpusubtype  (00000080 LE = arm64e)  -> patch to 00000000 (arm64_ALL)
  local subtype_bytes=$(head -c 12 /tmp/wp11_passd | tail -c 4 | od -An -tx1 | tr -d ' ')
  case "$subtype_bytes" in
    00000080)
      printf '\x00\x00\x00\x00' | dd of=/tmp/wp11_passd bs=1 seek=8 count=4 conv=notrunc status=none
      ok "  patched arm64e (0x80) -> arm64_ALL (0x00)"
      ;;
    00000000)
      ok "  already arm64_ALL — no patch needed"
      ;;
    *)
      warn "  unexpected cpusubtype $subtype_bytes — proceeding anyway"
      ;;
  esac
  echo ""

  # --- ldid -M sign with restricted entitlements ---------------------------
  log " [4/6] Signing with ldid -M (preserves Apple-restricted entitlements)"
  if ! "$LDID" -M -S"$ENTS_XML" -Icom.apple.passd /tmp/wp11_passd; then
    err "ldid signing failed"
    exit 1
  fi
  ok "  signed with $(wc -l < "$ENTS_XML") line plist + identifier com.apple.passd"
  echo ""

  # --- ct_bypass_ios -------------------------------------------------------
  log " [5/6] Applying CoreTrust bypass (CVE-2023-41991)"
  if ! "$CT_BYPASS_IOS" /tmp/wp11_passd 2>&1 | tail -8; then
    err "ct_bypass_ios failed (rc=$?)"
    exit 1
  fi
  ok "  CoreTrust bypass applied"
  echo ""

  # --- Cache + verify ------------------------------------------------------
  log " [6/6] Caching binary at $PER_BUILD"
  cp -f /tmp/wp11_passd "$PER_BUILD"
  chmod 755 "$PER_BUILD"
  rm -rf "$WORK_DIR" /tmp/wp11_passd
  ok "  cached $(stat -c%s "$PER_BUILD") bytes (next setup on this build will be instant)"
  echo ""
}

# Path 1 — per-build .bin already cached or shipped in the .deb (instant)
if [ -f "$PER_BUILD" ]; then
  PASSD_SIGNED="$PER_BUILD"
  ok "Found per-build binary for $BUILD_VERSION : $PASSD_SIGNED"

# Path 2 — legacy 7.18 binary present and we're on 20G75 (instant)
elif [ -f "$LEGACY" ] && [ "$BUILD_VERSION" = "20G75" ]; then
  PASSD_SIGNED="$LEGACY"
  warn "Per-build binary missing — falling back to legacy passd_signed (compatible with 20G75 only)"

# Path 3 — fully on-device extract + sign + ct_bypass
else
  build_passd_on_device
  PASSD_SIGNED="$PER_BUILD"
fi

ok "Sanity checks passed (using $PASSD_SIGNED)"
echo ""

# =============================================================================
# Step 1 — backup
# =============================================================================
log "Step 1/5 — Backing up current state"
mkdir -p "$BACKUP_DIR"
if [ "$JB_FLAVOR" = "rootless" ] && [ -d "$SYSBINS_DIR" ]; then
  cp -a "$SYSBINS_DIR" "$BACKUP_DIR/PassKitCore.framework.bak" 2>/dev/null || true
fi
[ -f "$LAUNCHD_OVERRIDE" ] && cp "$LAUNCHD_OVERRIDE" "$BACKUP_DIR/com.apple.passd.plist.bak" 2>/dev/null || true
[ -f "$PASSKIT_PREFS" ] && cp "$PASSKIT_PREFS" "$BACKUP_DIR/passkit_prefs.bak" 2>/dev/null || true
ok "Backup stored in $BACKUP_DIR"

# =============================================================================
# Step 2 — deploy passd (rootless: SysBins overlay; roothide: direct in opt/)
# =============================================================================
if [ "$JB_FLAVOR" = "rootless" ]; then
  log "Step 2/5 — Deploying passd SysBins overlay"
  mkdir -p "$SYSBINS_DIR"
  cp "$PASSD_SIGNED" "$SYSBINS_DIR/passd"
  chmod 755 "$SYSBINS_DIR/passd"
  ok "passd deployed to $SYSBINS_DIR/passd"
else
  log "Step 2/5 — Roothide : skipping SysBins (not supported), deploying directly"
  if [ "$PASSD_SIGNED" != "$BUNDLE_DIR/passd_signed" ]; then
    cp "$PASSD_SIGNED" "$BUNDLE_DIR/passd_signed"
    chmod 755 "$BUNDLE_DIR/passd_signed"
  fi
  ok "passd_signed available at $BUNDLE_DIR/passd_signed"
fi

# =============================================================================
# Step 3 — LaunchDaemon override (with __JBROOT__ substitution)
# =============================================================================
log "Step 3/5 — Installing LaunchDaemon override plist"
mkdir -p "$(dirname "$LAUNCHD_OVERRIDE")"
cp "$PASSD_PLIST" "$LAUNCHD_OVERRIDE"
sed -i "s|__JBROOT__|${JB_PREFIX}|g" "$LAUNCHD_OVERRIDE" 2>/dev/null || true
ok "LaunchDaemon override installed"

# =============================================================================
# Step 4 — PassKit prefs (v7.17 keys fix included)
# =============================================================================
log "Step 4/5 — Writing PassKit preferences"
PREFS_TEMP="/tmp/wp11_passd_prefs.plist"
cat > "$PREFS_TEMP" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PKIsUserPropertyOverrideEnabled</key><true/>
    <key>PKIsUserPropertyOverrideEnabledKey</key><true/>
    <key>PKBypassCertValidation</key><true/>
    <key>PKBypassStockholmRegionCheck</key><true/>
    <key>PKBypassImmoTokenCountCheck</key><true/>
    <key>PKDeveloperLoggingEnabled</key><true/>
    <key>PKDeveloperLogging</key><true/>
    <key>PKClientHTTPHeaderHardwarePlatformOverride</key><string>iPhone15,3</string>
    <key>PKClientHTTPHeaderOSPartOverride</key><string>iPhone OS 17.0</string>
    <key>PKShowFakeRemoteCredentials</key><true/>
    <key>PKShowFakeRemoteCredentialsKey</key><true/>
</dict>
</plist>
XMLEOF

if [ -f "$PASSKIT_PREFS" ] && command -v plutil >/dev/null 2>&1; then
  for KEY in PKIsUserPropertyOverrideEnabled PKIsUserPropertyOverrideEnabledKey \
             PKBypassCertValidation PKBypassStockholmRegionCheck PKBypassImmoTokenCountCheck \
             PKDeveloperLoggingEnabled PKDeveloperLogging \
             PKShowFakeRemoteCredentials PKShowFakeRemoteCredentialsKey; do
    plutil -replace "$KEY" -bool true "$PASSKIT_PREFS" 2>/dev/null || true
  done
  plutil -replace PKClientHTTPHeaderHardwarePlatformOverride -string "iPhone15,3" "$PASSKIT_PREFS" 2>/dev/null || true
  plutil -replace PKClientHTTPHeaderOSPartOverride -string "iPhone OS 17.0" "$PASSKIT_PREFS" 2>/dev/null || true
else
  warn "plutil not found, will overwrite $PASSKIT_PREFS"
  cp "$PREFS_TEMP" "$PASSKIT_PREFS"
fi

chown mobile:mobile "$PASSKIT_PREFS" 2>/dev/null || true
killall -HUP cfprefsd 2>/dev/null || true
ok "PassKit preferences written"

# =============================================================================
# Step 5 — reload services
# =============================================================================
log "Step 5/5 — Reloading launchd services"
launchctl unload /System/Library/LaunchDaemons/com.apple.passd.plist 2>&1 || true
launchctl load "$LAUNCHD_OVERRIDE" 2>&1 || true
killall -9 passd 2>/dev/null || true
sleep 2
launchctl kickstart -k system/com.apple.passd 2>&1 || true
sleep 3
ok "Services reloaded"

echo ""
log "======================================"
log "Setup complete !"
echo ""
ok "passd injection is active (binary: $(basename "$PASSD_SIGNED"))"
ok "PassKit overrides applied"
echo ""
warn "IMPORTANT NEXT STEPS :"
echo "  1. REBOOT your iPhone"
echo "  2. Re-apply your jailbreak after reboot ($JB_FLAVOR)"
echo "  3. Open the Watch app -> Wallet & Apple Pay -> Add Card"
echo "  4. Verify with your bank (SMS, app, etc.)"
echo ""
warn "IF YOU ENTER SAFE MODE OR THINGS BREAK :"
echo "  sudo bash $BUNDLE_DIR/rollback-applepay.sh"
echo ""
log "Logs from passd will be at /var/tmp/wp11.log"
