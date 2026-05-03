#!/bin/bash
# WatchPair11 — Apple Pay Setup Script
# Purpose: Deploy passd pipeline + PassKit preferences for Apple Pay
#          on watchOS 11.5 + iOS 16/17/18 (multi-iOS, v7.19+)
# Required: Root (sudo), nathanlr OR roothide jailbreak, WatchPair11 .deb already installed
# Tested:   iPhone 14 Pro Max iOS 16.6 build 20G75 + Apple Watch Series 10
#
# v7.19 — Multi-iOS + multi-jailbreak support :
#   - Per-build pre-signed passd binaries under $JB/opt/watchpair11/passd_signed_<BUILD>.bin
#     (e.g. passd_signed_20G75.bin). Auto-detect via `sw_vers -buildVersion`.
#   - Auto-detect rootless (nathanlr, /var/jb) vs roothide (jbroot CLI tool).
#   - Under roothide we skip SysBins overlay (not supported) and run passd directly
#     from $JB/opt/watchpair11/ via the LaunchDaemon override plist Program key.

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

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'; N='\033[0m'
log() { echo -e "${C}[WP11]${N} $1"; }
ok()  { echo -e "${G}[OK]${N}   $1"; }
err() { echo -e "${R}[ERR]${N}  $1" >&2; }
warn(){ echo -e "${Y}[WARN]${N} $1"; }

log "WatchPair11 Apple Pay Setup v7.19"
log "======================================"
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
# Locate the right pre-signed passd binary for this build (v7.19+)
# =============================================================================
PASSD_SIGNED=""
PER_BUILD="$BUNDLE_DIR/passd_signed_${BUILD_VERSION}.bin"
LEGACY="$BUNDLE_DIR/passd_signed"

if [ -f "$PER_BUILD" ]; then
  PASSD_SIGNED="$PER_BUILD"
  ok "Found per-build binary for $BUILD_VERSION : $PASSD_SIGNED"
elif [ -f "$LEGACY" ] && [ "$BUILD_VERSION" = "20G75" ]; then
  PASSD_SIGNED="$LEGACY"
  warn "Per-build binary missing — falling back to legacy passd_signed (compatible with 20G75 only)"
else
  err "No matching passd binary for build $BUILD_VERSION."
  err "Available pre-built binaries :"
  ls -1 "$BUNDLE_DIR"/passd_signed_*.bin 2>/dev/null | sed 's|.*/passd_signed_||; s|\.bin$||; s/^/  - /' || err "  (none)"
  err ""
  err "To add support for build $BUILD_VERSION :"
  err "  1. Extract passd from your iOS dyld_shared_cache (see docs-internal/MULTI_IOS_BUILD.md)"
  err "  2. Run: bash scripts/build_passd_for_ios_version.sh <passd> $BUILD_VERSION"
  err "  3. Reinstall the .deb"
  err "Or open an issue: https://github.com/plokijuter/WatchPair11/issues"
  exit 1
fi

ok "Sanity checks passed (using $PASSD_SIGNED)"
echo ""

# Step 1 — backup
log "Step 1/5 — Backing up current state"
mkdir -p "$BACKUP_DIR"
if [ "$JB_FLAVOR" = "rootless" ] && [ -d "$SYSBINS_DIR" ]; then
  cp -a "$SYSBINS_DIR" "$BACKUP_DIR/PassKitCore.framework.bak" 2>/dev/null || true
fi
[ -f "$LAUNCHD_OVERRIDE" ] && cp "$LAUNCHD_OVERRIDE" "$BACKUP_DIR/com.apple.passd.plist.bak" 2>/dev/null || true
[ -f "$PASSKIT_PREFS" ] && cp "$PASSKIT_PREFS" "$BACKUP_DIR/passkit_prefs.bak" 2>/dev/null || true
ok "Backup stored in $BACKUP_DIR"

# Step 2 — deploy passd (rootless: SysBins overlay; roothide: direct in opt/)
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

# Step 3 — LaunchDaemon override (with __JBROOT__ substitution)
log "Step 3/5 — Installing LaunchDaemon override plist"
mkdir -p "$(dirname "$LAUNCHD_OVERRIDE")"
cp "$PASSD_PLIST" "$LAUNCHD_OVERRIDE"
sed -i "s|__JBROOT__|${JB_PREFIX}|g" "$LAUNCHD_OVERRIDE" 2>/dev/null || true
ok "LaunchDaemon override installed"

# Step 4 — PassKit prefs (v7.17 keys fix included)
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

# Step 5 — reload services
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
echo "  3. Open the Watch app → Wallet & Apple Pay → Add Card"
echo "  4. Verify with your bank (SMS, app, etc.)"
echo ""
warn "IF YOU ENTER SAFE MODE OR THINGS BREAK :"
echo "  sudo bash $BUNDLE_DIR/rollback-applepay.sh"
echo ""
log "Logs from passd will be at /var/tmp/wp11.log"
