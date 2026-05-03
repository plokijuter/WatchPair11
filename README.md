# WatchPair11

Pair an **Apple Watch watchOS 11.5** (Series 10+) with an **iPhone iOS 16.6** (iPhone 14/15, arm64e) on the [nathanlr](https://github.com/verygenericname/nathanlr) jailbreak (or [roothide Dopamine 2.x](https://github.com/roothide/Dopamine2-roothide), v7.19+). Includes native **Apple Pay on Watch** provisioning (real SEP attestation, real bank 2FA, real NFC).

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

- **v7.19** — roothide variant (`com.watchpair11.roothide`) alongside the existing nathanlr/rootless build, single source tree. Same features. The setup/rollback scripts auto-detect which jailbreak is active. The pairing tweak code is unchanged ; only path resolution went through `jbroot()`.
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

### Rootless (nathanlr)

```bash
cd watchos26-tweak && make package THEOS=$HOME/theos
```

Output : `packages/com.watchpair11_7.19-X_iphoneos-arm64.deb`. APT repo regen : `bash scripts/regen-apt-repo.sh`.

### Roothide build

Requires a parallel roothide-flavored Theos checkout (the rootless and roothide schemes are not co-installable in one Theos tree):

```bash
# one-time setup — clone roothide/theos somewhere outside $HOME/theos
git clone --recursive https://github.com/roothide/theos $HOME/theos-roothide
$HOME/theos-roothide/bin/install-theos    # pulls roothide SDK + libroothide

# then, from this directory:
cd watchos26-tweak
make clean
make package SCHEME=roothide
# → packages/com.watchpair11.roothide_7.19-X_iphoneos-arm64.deb
```

`make clean` between schemes is mandatory because object files contain
scheme-specific paths baked into ldflags. The single source tree compiles
under both flavors via `#if __has_include(<roothide.h>)` guards in
`Tweak.xm`, `WP11Loader.c`, and `installer-app/Installer.m`.

There is **no public APT repo for the roothide variant yet** — install via
`dpkg -i com.watchpair11.roothide_7.19-X_iphoneos-arm64.deb` over SSH.
