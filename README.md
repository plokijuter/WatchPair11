# WatchPair11

## Description

WatchPair11 est un tweak iOS pour [nathanlr](https://github.com/verygenericname/nathanlr) (iOS 16.6) qui permet de jumeler une Apple Watch **watchOS 11.5** (Series 10+) avec un iPhone **iOS 16** (iPhone 14/15 arm64e). Bypass NanoRegistry + MobileAsset + CFPreferences + **Apple Pay provisioning** (v7.15+).

> **Ce repo n'est pas activement maintenu.** C'est un projet personnel qui répond à un besoin spécifique (garder iOS 16 avec une Watch récente). Les issues et PRs seront lus mais pas forcément traités rapidement. Utilisez à vos risques.

## Fonctionnalités qui MARCHENT

- **Pairing watchOS 11.5 ↔ iOS 16** (iPhone 14 Pro Max testé avec Apple Watch Series 10)
- **BLE drain fix** (batterie normale, bloc 0x00 BLE NearbyAction type)
- **Apple Messages (iMessage)** sur Watch : envoi + réception + notifications
- **Toutes les notifications 3rd-party** arrivent sur Watch (Facebook Messenger, WhatsApp, etc.)
- **Réponse aux notifications** depuis Watch (via UI watchOS générique)
- **Pairing stable** après reboot + re-JB
- **🆕 Apple Pay "Ajouter carte" à la Watch** (v7.15+, voir setup spécifique ci-dessous)

## Fonctionnalités qui NE MARCHENT PAS

- **Icône Facebook Messenger sur écran d'accueil Watch** : Facebook a retiré son app Watch depuis 2018. L'app iPhone Messenger ne contient plus de bundle watchOS. Les notifications arrivent quand même (via système iOS).
- **watchOS updates via iPhone pairing** : iOS 16 ne supporte pas officiellement watchOS 11+, donc impossible de faire des updates watchOS depuis le pairing iPhone.

## Prérequis

- iPhone supporté par nathanlr (iPhone 14 Pro Max testé, iOS 16.5.1 - 16.7.x sur A15/A16)
- nathanlr jailbreak installé (https://github.com/verygenericname/nathanlr)
- Sileo ou autre package manager

## Installation

1. Télécharge le `.deb` depuis [Releases](https://github.com/plokijuter/WatchPair11/releases)
2. Installe via Sileo (ouvre `.deb` avec Sileo)
3. Respring
4. (La première fois) Pair ta Apple Watch watchOS 11.5 normalement

## 🆕 Setup Apple Pay (v7.15+)

Le provisioning Apple Pay nécessite une configuration manuelle supplémentaire car les daemons PassKit nécessitent une injection via SysBins + CoreTrust bypass, non couverte par nathanlr.

### Étape 1 : Build ct_bypass_linux (arm64e capable)

Notre port Linux de ChOma `ct_bypass` supporte désormais arm64e (contribution unique). Depuis un host Linux/WSL :

```bash
cd ctbypass_artifacts/
bash build_linux_ctbp.sh
# → Produit /tmp/ts_build/out/ct_bypass_linux
```

### Étape 2 : Signer passd avec notre TeamID bypass

```bash
# Pull original passd depuis iPhone
scp mobile@iphone:/System/Library/PrivateFrameworks/PassKitCore.framework/passd /tmp/passd

# Prep entitlements (strip seatbelt, ajoute platform-application + get-task-allow)
ldid -e /tmp/passd > /tmp/passd_orig_ents.plist
# (utiliser prep_passd_ents.py pour l'auto-prep)

# arm64e → arm64 patch + sign
printf '\x00\x00\x00\x00' | dd of=/tmp/passd bs=1 seek=8 count=4 conv=notrunc
ldid -S/tmp/passd_final_ents.xml -Icom.apple.passd /tmp/passd
/tmp/ts_build/out/ct_bypass_linux /tmp/passd
# → passd signé TeamID T8ALTGMVXN via CVE-2023-41991
```

### Étape 3 : Deploy SysBins pipeline

```bash
# Sur iPhone (via SSH avec sudo)
sudo mkdir -p /var/jb/System/Library/SysBins/PassKitCore.framework
sudo cp /tmp/passd /var/jb/System/Library/SysBins/PassKitCore.framework/passd
sudo chmod 755 /var/jb/System/Library/SysBins/PassKitCore.framework/passd

# Override plist pour que launchd utilise notre binaire avec DYLD_INSERT
sudo cp com.apple.passd.bin.plist /var/jb/Library/LaunchDaemons/com.apple.passd.plist
sudo launchctl unload /System/Library/LaunchDaemons/com.apple.passd.plist
sudo launchctl load /var/jb/Library/LaunchDaemons/com.apple.passd.plist
```

### Étape 4 : Override PassKit preferences

Ajoute ces clés dans `/var/mobile/Library/Preferences/com.apple.passd.plist` :

```xml
<key>PKIsUserPropertyOverrideEnabled</key><true/>
<key>PKBypassCertValidation</key><true/>
<key>PKBypassStockholmRegionCheck</key><true/>
<key>PKBypassImmoTokenCountCheck</key><true/>
<key>PKDeveloperLoggingEnabled</key><true/>
<key>PKClientHTTPHeaderHardwarePlatformOverride</key><string>iPhone15,3</string>
<key>PKClientHTTPHeaderOSPartOverride</key><string>iPhone OS 17.0</string>
<key>PKShowFakeRemoteCredentials</key><true/>
```

`PKShowFakeRemoteCredentials` est le dernier ingrédient qui fait que la carte apparaît comme validée côté Watch.

### Étape 5 : Reboot + re-JB

Obligatoire pour clean les caches AMFI/launchd. Après reboot + re-JB :
1. Open app Watch → Wallet et Apple Pay → Ajouter carte
2. Flow complet avec validation banque (Desjardins/etc.)
3. Carte activée sur Watch

## Credits / Remerciements

Ce projet n'aurait pas été possible sans le travail de :

- **[577fkj/WatchFix](https://github.com/577fkj/WatchFix)** (GPLv3) : Source d'inspiration pour les hooks `APSSupport`, `AppsSupport`, `IDSUTun`.
- **[opa334/ChOma](https://github.com/opa334/ChOma)** (MIT) : Bibliothèque de parsing Mach-O + exploit CoreTrust CVE-2023-41991. Nous avons porté `ct_bypass` vers Linux/WSL avec **support arm64e** (contribution originale, voir ci-dessous).
- **[opa334/TrollStore](https://github.com/opa334/TrollStore)** : Source de `fastPathSign` + pattern d'injection.
- **[verygenericname/nathanlr](https://github.com/verygenericname/nathanlr)** : Le jailbreak semi-tethered qui rend tout ce projet possible sur iOS 16.5.1 - 16.7.x A15/A16.
- **[verygenericname/nathanlr_hooks](https://github.com/verygenericname/nathanlr_hooks)** : Les hooks `launchd`/`generalhook`/`xpcproxy` pour l'injection dans SysBins.
- **[SerotoninApp/Serotonin](https://github.com/SerotoninApp/Serotonin)** : Base de `launchdhook`.
- **[Dopamine / opa334](https://github.com/opa334/Dopamine)** : Référence pour `systemhook`.
- **Legizmo Moonstone (lunotech11)** : Référence commerciale, approche technique et classes cibles.

## Architecture technique

Le tweak injecte dans 5 processus iOS 16 :

- **SpringBoard** : spoof version iOS 18.5, hook CFPreferences pairing compatibility, PassKit compat
- **bluetoothd** : BLE drain fix (block NearbyAction type 0x00)
- **appconduitd** : `AppsSupport` hook (MobileSMS supplemental mapping)
- **installd** : `MIEmbeddedWatchBundle` version spoof (watchOS 11.9999)
- **passd** (v7.15+ via SysBins) : Apple Pay provisioning hooks + NRDevice productType spoof

Les 2 daemons `apsd` et `identityservicesd` sont **intentionnellement non-injectés** :

- `apsd` : hook APSSupport cassait les push notifs 3rd-party (v7.6 revert)
- `identityservicesd` : hook IMService causait SIGSEGV dans Logos ctor (v7.4 revert)

## Contribution originale : ct_bypass_linux arm64e support

Le port Linux de ChOma's `ct_bypass` originalement ne supportait que arm64. Nous avons ajouté le support arm64e, nécessaire pour signer les binaires iPhone 14/15 (qui sont arm64e PAC).

Fix principal dans `ctbypass_artifacts/` :

1. **`Host.c`** : Fallback pour Linux cross-compile (sysctlbyname retourne -1 sinon) :
```c
if (sysctlbyname("hw.cputype", cputype, &len, NULL, 0) == -1) {
    *cputype = 0x100000c;  // CPU_TYPE_ARM64
    *cpusubtype = 2;       // CPU_SUBTYPE_ARM64E
    return 0;
}
```

2. **`main_linux.c`** : Include missing `Host.h` (sans ça, return pointer truncated 64→32 bit → segfault) :
```c
#include "Host.h"
```

Le ct_bypass_linux résultant peut signer tout binaire iOS arm64 ou arm64e avec TeamID T8ALTGMVXN via CVE-2023-41991, depuis un host Linux sans Mac. Utile pour tout projet qui a besoin de resigner des daemons iOS arm64e.

## Source du ct_bypass_linux

Le sous-dossier `ctbypass_artifacts/` contient :

- `ct_bypass_linux` : binaire Linux x86_64 qui signe des Mach-O iOS arm64/arm64e avec bypass CoreTrust
- `build_linux_ctbp.sh` : script build
- `compat_headers/` : shims Apple (mach, mach-o, libkern, CommonCrypto)
- `coretrust_bug_libplist_patch.c` : version patched de `coretrust_bug.c` utilisant libplist au lieu de CoreFoundation
- `main_linux.c` : wrapper minimal pour Linux host
- `prepare_daemon.sh` : pipeline complet (patch arm64 + ldid sign + ct_bypass)

## Changelog

- **v7.15** (actuel) : **🏆 Apple Pay Watch provisioning works !** Combinaison de :
  - Hooks `NPKIsConnectedToPairedOrPairingDeviceFromService`, `NPKIsCurrentlyPairing`, et 3 autres NPK C gates dans passd
  - Hook `PKProductTypeFromNRDevice` via MSHookFunction (productType Watch6,14)
  - NSUserDefaults overrides native Apple PassKit (PKBypassStockholmRegionCheck, PKShowFakeRemoteCredentials, etc.)
  - ct_bypass_linux arm64e support (contribution originale)
  - passd SysBins pipeline avec override LaunchDaemon plist
- **v7.14** : Narrow productType spoof pour éviter break Bridge/SpringBoard launch
- **v7.13** : Watch productType spoof (Series 10 → Series 8 apparent pour iOS 16 compat)
- **v7.12** : Listener Darwin notifications dans SpringBoard pour trace Bridge activity
- **v7.11** : Minimal NPKCompanionAgent hook (canAddSecureElementPass)
- **v7.10** : Hook posix_spawn dans xpcproxy pour Bridge injection (approche abandonnée)
- **v7.9** : Surgical NPK hooks dans passd (sans NSUserDefaults aggressive)
- **v7.8** : hookPassd dans SpringBoard + Bridge + NPKCompanionAgent
- **v7.7** : NSUserDefaults PassKit override keys (PKDeveloperSettingsEnabled, PKBypassCertValidation, etc.)
- **v7.6** : Désactive `hookAPSSupport` (cassait push notifs 3rd-party)
- **v7.4** : Retire `identityservicesd` du filter (crash Logos ctor)
- **v7.3** : Integration hooks WatchFix (APSSupport, AppsSupport, IDSUTun)
- **v6.9** : Recette initiale validée (SpringBoard + bluetoothd seulement)

## Limitations connues

- Tweak développé sur iPhone 14 Pro Max iOS 16.6 + Apple Watch Series 10 watchOS 11.5. Autres combinaisons non testées.
- Apple Pay setup (v7.15+) nécessite step-by-step manuel (voir section "Setup Apple Pay"). Pas automatisé via .deb install.
- Si le Watch ne répond pas physiquement au NFC (terminal de paiement), `PKShowFakeRemoteCredentials` n'a fait qu'un bypass UI. Le SE provisioning réel dépend de la santé du flow Apple Pay, testable seulement à un vrai terminal.

## Installation depuis les sources

```bash
make package
```

### Via SSH

```bash
scp -P 8056 packages/*.deb mobile@127.0.0.1:/var/mobile/Documents/
ssh -p 8056 mobile@127.0.0.1 "echo '<password>' | sudo -S dpkg -i /var/mobile/Documents/com.watchpair11.tweak_*.deb"
```

Après l'installation, **rejailbreak** (relancer nathanlr) pour que tous les hooks SysBins soient actifs.
