#!/bin/bash
# WatchPair11 — Apple Pay Rollback Script
# Reverts setup-applepay.sh changes. Use if Apple Pay setup breaks things or safe mode.

set -e

JB_PREFIX="/var/jb"
BUNDLE_DIR="$JB_PREFIX/opt/watchpair11"
BACKUP_DIR="$BUNDLE_DIR/backup"
SYSBINS_DIR="$JB_PREFIX/System/Library/SysBins/PassKitCore.framework"
LAUNCHD_OVERRIDE="$JB_PREFIX/Library/LaunchDaemons/com.apple.passd.plist"
PASSKIT_PREFS="/var/mobile/Library/Preferences/com.apple.passd.plist"

R='\033[0;31m'
G='\033[0;32m'
C='\033[0;36m'
N='\033[0m'

log() { echo -e "${C}[WP11]${N} $1"; }
ok()  { echo -e "${G}[OK]${N}   $1"; }
err() { echo -e "${R}[ERR]${N}  $1" >&2; }

log "WatchPair11 Apple Pay Rollback"
log "==============================="
echo ""

if [ "$EUID" -ne 0 ]; then
  err "Must run as root : sudo bash $0"
  exit 1
fi

# Remove passd SysBins injection
log "Removing passd SysBins"
if [ -d "$SYSBINS_DIR" ]; then
  rm -rf "$SYSBINS_DIR"
  ok "Removed $SYSBINS_DIR"
fi

# Remove LaunchDaemon override
log "Removing LaunchDaemon override"
launchctl unload "$LAUNCHD_OVERRIDE" 2>&1 || true
rm -f "$LAUNCHD_OVERRIDE"
ok "Removed $LAUNCHD_OVERRIDE"

# Reload native passd plist
launchctl load /System/Library/LaunchDaemons/com.apple.passd.plist 2>&1 || true

# Restore PassKit prefs backup if exists
if [ -f "$BACKUP_DIR/passkit_prefs.bak" ]; then
  log "Restoring PassKit prefs from backup"
  cp "$BACKUP_DIR/passkit_prefs.bak" "$PASSKIT_PREFS"
  chown mobile:mobile "$PASSKIT_PREFS"
  ok "Prefs restored"
else
  log "No backup found — removing our override keys only (keeping other prefs)"
  if command -v plutil >/dev/null 2>&1; then
    for KEY in PKIsUserPropertyOverrideEnabled PKIsUserPropertyOverrideEnabledKey \
               PKBypassCertValidation PKBypassStockholmRegionCheck \
               PKBypassImmoTokenCountCheck \
               PKDeveloperLoggingEnabled PKDeveloperLogging \
               PKShowFakeRemoteCredentials PKShowFakeRemoteCredentialsKey \
               PKClientHTTPHeaderHardwarePlatformOverride PKClientHTTPHeaderOSPartOverride; do
      plutil -remove "$KEY" "$PASSKIT_PREFS" 2>/dev/null || true
    done
    ok "Override keys removed"
  fi
fi

killall -HUP cfprefsd 2>/dev/null || true
killall -9 passd 2>/dev/null || true
sleep 2

echo ""
log "Rollback complete"
log "passd is now running native without our injection"
echo ""
log "REBOOT recommended for clean state"
