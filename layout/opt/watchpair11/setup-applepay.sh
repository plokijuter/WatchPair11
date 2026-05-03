#!/bin/bash
# WatchPair11 — Apple Pay Setup Script
# Purpose: Deploy passd SysBins pipeline + PassKit preferences for Apple Pay
#          on watchOS 11.5 + iOS 16/17/18 (multi-iOS, v7.19+)
# Required: Root (sudo), nathanlr jailbreak, WatchPair11 .deb already installed
# Tested:   iPhone 14 Pro Max iOS 16.6 build 20G75 + Apple Watch Series 10
#
# v7.19 — Multi-iOS support : the .deb now ships per-build pre-signed
#         passd binaries under /var/jb/opt/watchpair11/passd_signed_<BUILD>.bin
#         (e.g. passd_signed_20G75.bin). This script auto-detects the device
#         build via `sw_vers -buildVersion` and picks the matching binary.
#         If only the legacy (suffix-less) `passd_signed` is present, it is
#         used as a fallback when the device runs build 20G75.

set -e

# =============================================================================
# CONFIG
# =============================================================================
JB_PREFIX="/var/jb"
BUNDLE_DIR="$JB_PREFIX/opt/watchpair11"
PASSD_PLIST="$BUNDLE_DIR/com.apple.passd.plist"
SYSBINS_DIR="$JB_PREFIX/System/Library/SysBins/PassKitCore.framework"
LAUNCHD_OVERRIDE="$JB_PREFIX/Library/LaunchDaemons/com.apple.passd.plist"
BACKUP_DIR="$JB_PREFIX/opt/watchpair11/backup"
PASSKIT_PREFS="/var/mobile/Library/Preferences/com.apple.passd.plist"

# Colors
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
C='\033[0;36m'
N='\033[0m'

log() { echo -e "${C}[WP11]${N} $1"; }
ok()  { echo -e "${G}[OK]${N}   $1"; }
err() { echo -e "${R}[ERR]${N}  $1" >&2; }
warn(){ echo -e "${Y}[WARN]${N} $1"; }

# =============================================================================
# SANITY CHECKS
# =============================================================================
log "WatchPair11 Apple Pay Setup v7.19"
log "======================================"
echo ""

# Must be root
if [ "$EUID" -ne 0 ]; then
  err "This script must run as root. Run with: sudo bash $0"
  exit 1
fi

# Detect iOS build
IOS_VERSION=$(sw_vers -productVersion 2>/dev/null || uname -r)
BUILD_VERSION=$(sw_vers -buildVersion 2>/dev/null || echo "unknown")
log "iOS version detected: $IOS_VERSION (build $BUILD_VERSION)"

# Check nathanlr base path
[ -d "$JB_PREFIX" ] || { err "Nathanlr jailbreak path $JB_PREFIX not found."; exit 1; }
[ -f "$PASSD_PLIST" ] || { err "Override plist missing: $PASSD_PLIST"; exit 1; }

# =============================================================================
# Locate the right pre-signed passd binary for this build
# =============================================================================
# v7.19 layout :
#   $BUNDLE_DIR/passd_signed_20G75.bin  ← per-build (preferred)
#   $BUNDLE_DIR/passd_signed_21E236.bin
#   $BUNDLE_DIR/passd_signed             ← legacy 7.18 path (only used if build = 20G75)

PASSD_SIGNED=""
PER_BUILD="$BUNDLE_DIR/passd_signed_${BUILD_VERSION}.bin"
LEGACY="$BUNDLE_DIR/passd_signed"

if [ -f "$PER_BUILD" ]; then
  PASSD_SIGNED="$PER_BUILD"
  ok "Found per-build binary for $BUILD_VERSION : $PASSD_SIGNED"
elif [ -f "$LEGACY" ] && [ "$BUILD_VERSION" = "20G75" ]; then
  PASSD_SIGNED="$LEGACY"
  warn "Per-build binary missing — falling back to legacy passd_signed (compatible with 20G75 only)"
elif [ -f "$LEGACY" ] && [ "$BUILD_VERSION" != "20G75" ]; then
  err "No matching passd binary for build $BUILD_VERSION."
  err "The legacy $LEGACY is only safe on iOS 16.6 build 20G75."
  err ""
  err "Available pre-built binaries :"
  for f in "$BUNDLE_DIR"/passd_signed_*.bin; do
    [ -f "$f" ] || continue
    err "  - $(basename "$f" .bin | sed 's/^passd_signed_//') ($f)"
  done
  err ""
  err "To add support for build $BUILD_VERSION :"
  err "  1. Extract passd from your iOS dyld_shared_cache (see docs-internal/MULTI_IOS_BUILD.md)"
  err "  2. Run: bash scripts/build_passd_for_ios_version.sh <passd> $BUILD_VERSION"
  err "  3. Reinstall the .deb"
  err ""
  err "Or open an issue : https://github.com/plokijuter/WatchPair11/issues"
  exit 1
else
  err "No passd binary found in $BUNDLE_DIR for build $BUILD_VERSION."
  err ""
  err "Expected one of :"
  err "  - $PER_BUILD"
  err "  - $LEGACY (only valid on 20G75)"
  err ""
  err "Available pre-built binaries :"
  ls -1 "$BUNDLE_DIR"/passd_signed_*.bin 2>/dev/null | sed 's|.*/passd_signed_||; s|\.bin$||; s/^/  - /' || err "  (none)"
  err ""
  err "To add support for build $BUILD_VERSION :"
  err "  1. Extract passd from your iOS dyld_shared_cache (see docs-internal/MULTI_IOS_BUILD.md)"
  err "  2. Run: bash scripts/build_passd_for_ios_version.sh <passd> $BUILD_VERSION"
  err "  3. Reinstall the .deb"
  err ""
  err "Or open an issue : https://github.com/plokijuter/WatchPair11/issues"
  exit 1
fi

ok "Sanity checks passed (using $PASSD_SIGNED)"
echo ""

# =============================================================================
# STEP 1 : Backup current state
# =============================================================================
log "Step 1/5 — Backing up current state"
mkdir -p "$BACKUP_DIR"
if [ -d "$SYSBINS_DIR" ]; then
  cp -a "$SYSBINS_DIR" "$BACKUP_DIR/PassKitCore.framework.bak" 2>/dev/null || true
fi
if [ -f "$LAUNCHD_OVERRIDE" ]; then
  cp "$LAUNCHD_OVERRIDE" "$BACKUP_DIR/com.apple.passd.plist.bak" 2>/dev/null || true
fi
if [ -f "$PASSKIT_PREFS" ]; then
  cp "$PASSKIT_PREFS" "$BACKUP_DIR/passkit_prefs.bak" 2>/dev/null || true
fi
ok "Backup stored in $BACKUP_DIR"

# =============================================================================
# STEP 2 : Deploy passd SysBins
# =============================================================================
log "Step 2/5 — Deploying passd SysBins (signed with TeamID T8ALTGMVXN)"
mkdir -p "$SYSBINS_DIR"
cp "$PASSD_SIGNED" "$SYSBINS_DIR/passd"
chmod 755 "$SYSBINS_DIR/passd"
ok "passd deployed to $SYSBINS_DIR/passd"

# =============================================================================
# STEP 3 : Deploy override LaunchDaemon plist
# =============================================================================
log "Step 3/5 — Installing LaunchDaemon override plist"
mkdir -p "$(dirname "$LAUNCHD_OVERRIDE")"
cp "$PASSD_PLIST" "$LAUNCHD_OVERRIDE"
ok "LaunchDaemon override installed"

# =============================================================================
# STEP 4 : Write PassKit preferences
# =============================================================================
log "Step 4/5 — Writing PassKit preferences to $PASSKIT_PREFS"

PREFS_TEMP="/tmp/wp11_passd_prefs.plist"
# v7.17 — fix issue #2 (credit @577fkj) : real CFPreferences/NSUserDefaults keys differ from Apple's exported symbol names.
#   PKIsUserPropertyOverrideEnabled  → PKIsUserPropertyOverrideEnabledKey
#   PKDeveloperLoggingEnabled        → PKDeveloperLogging
#   PKShowFakeRemoteCredentials      → PKShowFakeRemoteCredentialsKey
# Both legacy + correct keys are written (additive) for safety.
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

# Merge with existing prefs (preserve existing keys)
if [ -f "$PASSKIT_PREFS" ] && command -v plutil >/dev/null 2>&1; then
  # plutil-based merge (iOS native)
  for KEY in PKIsUserPropertyOverrideEnabled PKIsUserPropertyOverrideEnabledKey \
             PKBypassCertValidation PKBypassStockholmRegionCheck \
             PKBypassImmoTokenCountCheck \
             PKDeveloperLoggingEnabled PKDeveloperLogging \
             PKShowFakeRemoteCredentials PKShowFakeRemoteCredentialsKey; do
    plutil -replace "$KEY" -bool true "$PASSKIT_PREFS" 2>/dev/null || true
  done
  plutil -replace PKClientHTTPHeaderHardwarePlatformOverride -string "iPhone15,3" "$PASSKIT_PREFS" 2>/dev/null || true
  plutil -replace PKClientHTTPHeaderOSPartOverride -string "iPhone OS 17.0" "$PASSKIT_PREFS" 2>/dev/null || true
else
  # Fallback : overwrite with our version (loses existing prefs, user should back up first)
  warn "plutil not found, will overwrite $PASSKIT_PREFS (losing existing keys)"
  cp "$PREFS_TEMP" "$PASSKIT_PREFS"
fi

chown mobile:mobile "$PASSKIT_PREFS" 2>/dev/null || true

# Force cfprefsd reload
killall -HUP cfprefsd 2>/dev/null || true
ok "PassKit preferences written"

# =============================================================================
# STEP 5 : Reload launchd services
# =============================================================================
log "Step 5/5 — Reloading launchd services"
launchctl unload /System/Library/LaunchDaemons/com.apple.passd.plist 2>&1 || true
launchctl load "$LAUNCHD_OVERRIDE" 2>&1 || true
killall -9 passd 2>/dev/null || true
sleep 2
launchctl kickstart -k system/com.apple.passd 2>&1 || true
sleep 3
ok "Services reloaded"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
log "======================================"
log "Setup complete !"
echo ""
ok "passd injection is active (binary: $(basename "$PASSD_SIGNED"))"
ok "PassKit overrides applied"
echo ""
warn "IMPORTANT NEXT STEPS :"
echo "  1. REBOOT your iPhone"
echo "  2. Re-apply nathanlr jailbreak after reboot"
echo "  3. Open the Watch app → Wallet & Apple Pay → Add Card"
echo "  4. Verify with your bank (SMS, app, etc.)"
echo "  5. Card should appear verified on Watch"
echo ""
warn "IF YOU ENTER SAFE MODE OR THINGS BREAK :"
echo "  sudo bash /var/jb/opt/watchpair11/rollback-applepay.sh"
echo ""
log "Logs from passd will be at /var/tmp/wp11.log"
log "Witness file (confirms hook load) : /var/tmp/wp11_passd.txt"
