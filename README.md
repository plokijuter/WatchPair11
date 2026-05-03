# WatchPair11

Pair an **Apple Watch watchOS 11.5** (Series 10+) with an **iPhone iOS 16.6** (iPhone 14/15, arm64e) on the [nathanlr](https://github.com/verygenericname/nathanlr) jailbreak (or any rootless-compatible jailbreak like [Dopamine 2.x roothide](https://github.com/roothide/Dopamine2-roothide)). Includes native **Apple Pay on Watch** provisioning (real SEP attestation, real bank 2FA, real NFC).

> Personal project, not actively maintained. Issues/PRs are read but may not be answered quickly.

## 📦 Install

### One-tap (open on your iOS device)

# 👉 [**plokijuter.github.io/WatchPair11/**](https://plokijuter.github.io/WatchPair11/)

The landing page has working **Add to Cydia / Sileo / Zebra** buttons.

### Manual

Add this repo URL in your package manager :

```
https://plokijuter.github.io/WatchPair11/
```

Or grab the `.deb` from the [latest release](https://github.com/plokijuter/WatchPair11/releases/latest).

## What works

- Pairing watchOS 11.5 ↔ iOS 16.6
- BLE drain fix
- iMessage + 3rd-party notifications on Watch (FB Messenger, WhatsApp, …)
- **Apple Pay "Add Card" on Watch** (v7.15+, optional one-tap setup via the installer app)

## What doesn't

- Facebook Messenger Watch app icon (FB removed it in 2018)
- watchOS updates via iPhone pairing

## Requirements

- iPhone 14 / 15 (arm64e), iOS 16.5.1 – 16.7.x
- nathanlr **or** roothide Dopamine 2.x jailbreak active
- Sileo (or Zebra / Cydia)

## Apple Pay setup

After installing the tweak, the easiest path is the **WatchPair11 Installer** app (one-tap setup, also from the repo). Or use the SSH scripts at `<jbroot>/opt/watchpair11/{setup,rollback}-applepay.sh`.

If safe mode hits :
```bash
# nathanlr
sudo bash /var/jb/opt/watchpair11/rollback-applepay.sh
# roothide
sudo bash "$(jbroot)/opt/watchpair11/rollback-applepay.sh"
```

## Changelog

See [Releases](https://github.com/plokijuter/WatchPair11/releases). Highlights :

- **v8.0** — Full on-device Apple Pay pipeline. Works on **any iOS build** out of the box, no maintainer effort per release. The first `Setup Apple Pay` tap on a non-canonical build extracts `passd` from the device's own dyld_shared_cache, patches it, ldid-signs it and applies the CoreTrust bypass — all on the iPhone in ~30-60 seconds. Subsequent runs are instant (cached). The pre-built `passd_signed_20G75.bin` for iOS 16.6 is still bundled, so canonical-build users see no change. See `docs-internal/V8_ON_DEVICE_PIPELINE.md`. Architecture simplification: single .deb for both nathanlr and roothide (was 2 separate builds in v7.19). Roothide compatibility now via runtime detection in `setup-applepay.sh` — no source changes needed for the JB difference.
- **v7.19** — Multi-iOS Apple Pay support + roothide variant. (a) Per-build pre-signed `passd` binaries (e.g. `passd_signed_20G75.bin`) — `setup-applepay.sh` auto-detects the device build and picks the matching binary. Currently bundled : 20G75 (iOS 16.6). To add a build, run `scripts/build_passd_for_ios_version.sh <passd> <buildId>`. See `docs-internal/MULTI_IOS_BUILD.md`. (b) Parallel roothide variant (`com.watchpair11.roothide`) from the same source tree. Setup/rollback scripts auto-detect rootless vs roothide. Path resolution wrapped in `jbroot()`.
- **v7.18** — single `com.watchpair11` package : tweak + home-screen app + Apple Pay scripts in one .deb. Auto-replaces the old split packages. App now has Respring + Userspace Reboot buttons.
- **v7.17** — fix PassKit pref keys ([issue #2](https://github.com/plokijuter/WatchPair11/issues/2), credit [@577fkj](https://github.com/577fkj)) + GPG-signed APT repo
- **v7.16** — home-screen installer app, scripts automation
- **v7.15** — 🏆 Apple Pay Watch provisioning works

## Credits

- **[577fkj/WatchFix](https://github.com/577fkj/WatchFix)** — APSSupport / AppsSupport / IDSUTun hooks (GPLv3) + [issue #2](https://github.com/plokijuter/WatchPair11/issues/2) reverse engineering of PassKit pref keys
- **[opa334/ChOma](https://github.com/opa334/ChOma)** — Mach-O parsing + CoreTrust CVE-2023-41991 (we ported `ct_bypass` to Linux with arm64e support)
- **[opa334/TrollStore](https://github.com/opa334/TrollStore)** — fastPathSign + injection patterns
- **[verygenericname/nathanlr](https://github.com/verygenericname/nathanlr)** — the jailbreak this targets
- **[roothide/Dopamine2-roothide](https://github.com/roothide/Dopamine2-roothide)** — alternative jailbreak now supported in v7.19+

## Build from source

```bash
cd watchos26-tweak
bash tools/fetch_external.sh        # one-time : pulls libcrypto.a/libssl.a (~47 MB, gitignored)
make package THEOS=$HOME/theos
```

Output : `packages/com.watchpair11_8.0-X_iphoneos-arm64.deb`. The same .deb installs cleanly on both nathanlr (rootless / MobileSubstrate) and roothide (Dopamine 2.x / ElleKit) — see the `Depends: ellekit | mobilesubstrate ...` line in `control`. APT repo regen : `bash scripts/regen-apt-repo.sh`.
