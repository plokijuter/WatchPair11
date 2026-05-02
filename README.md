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
- **🆕 Apple Pay "Ajouter carte" à la Watch** (v7.15+, setup optionnel séparé)

## Fonctionnalités qui NE MARCHENT PAS

- **Icône Facebook Messenger sur écran d'accueil Watch** : Facebook a retiré son app Watch depuis 2018.
- **watchOS updates via iPhone pairing** : iOS 16 ne supporte pas officiellement watchOS 11+.

## Prérequis

- iPhone supporté par nathanlr (iPhone 14 Pro Max testé, iOS 16.5.1 - 16.7.x sur A15/A16)
- nathanlr jailbreak installé (https://github.com/verygenericname/nathanlr)
- Sileo ou autre package manager

## Installation de base (pairing + notifs, SANS Apple Pay)

```bash
# 1. Télécharge le .deb depuis Releases
# 2. Installe via Sileo (Ouvre .deb avec Sileo)
# 3. Respring
```

Après install tu auras : pairing watchOS 11.5, BLE drain fix, iMessage/notifs Watch. **Apple Pay n'est PAS activé par défaut** — c'est une étape séparée ci-dessous.

## 🆕 Apple Pay Setup — 4 options

### Option 0 — Home-screen installer app (LE PLUS SIMPLE, recommandé débutants)

1. Download `com.watchpair11.installer_1.0-1_iphoneos-arm64.deb` depuis [Releases](https://github.com/plokijuter/WatchPair11/releases/latest)
2. Install via Sileo → respring
3. Tap icône **WatchPair11** sur home screen
4. Boutons :
   - **1. Install Pairing + Notifs** — déploie la dylib + filter, kill daemons
   - **2. Install Apple Pay** — deploy passd SysBins + override + 8 prefs (confirm dialog)
   - **Rollback All** — restore état de base, efface Apple Pay setup
5. Reboot + re-JB après Apple Pay install

L'app embed toutes les ressources (`WatchPair11.dylib`, `passd_signed`, override plist, prefs). Aucun SSH, aucun terminal, backup auto, log live scrollable dans l'UI. Fonctionne via `sudo_spawn_root` pour l'élévation.

**Note** : l'installer app **remplace** le `.deb` principal du tweak pour qui préfère cette approche. Si tu l'utilises, tu n'as PAS besoin d'installer `com.watchpair11.tweak_*.deb` séparément.

## Apple Pay Setup — options classiques (SSH / dpkg)

**⚠️ Pourquoi le setup est séparé de l'install de base :**

Apple Pay nécessite de signer et déployer un `passd` custom via SysBins (pipeline CoreTrust bypass). Ce setup :
- Est **spécifique à ton build iOS exact** (binaire passd bundled est pour iOS 16.6 build 20G75)
- Nécessite **root + reboot + re-JB** pour prendre effet
- Peut causer **safe mode** si ton setup diffère (iPhone différent, iOS différent)

Donc on le sépare de l'install de base pour éviter de brick des devices incompatibles.

### Option 1 — Setup automatique lors de l'installation

Si tu es sur **iOS 16.6 build 20G75 exactement** (vérifier via `Settings → General → About`) :

```bash
# Sur iPhone via Terminal (NewTerm / etc.)
export WATCHPAIR11_AUTO_APPLEPAY=1
sudo dpkg -i /path/to/com.watchpair11.tweak_7.16-*.deb
```

Le postinst va auto-exécuter le script Apple Pay. Reboot + Re-JB ensuite.

### Option 2 — Setup manuel (RECOMMANDÉ, plus safe)

Installation standard du .deb, puis lance le setup quand tu es prêt :

```bash
# 1. Install standard
sudo dpkg -i /path/to/com.watchpair11.tweak_7.16-*.deb

# 2. Teste d'abord l'install de base (pairing, notifs)
#    Respring + verify app Watch s'ouvre normalement

# 3. QUAND PRÊT, lance le setup Apple Pay
sudo bash /var/jb/opt/watchpair11/setup-applepay.sh

# 4. Reboot + Re-JB nathanlr

# 5. Add card via app Watch → Wallet
```

Ce script fait des sanity checks (version iOS, fichiers présents), **backup ton état actuel avant modifs**, puis déploie. Si erreur → t'affiche comment rollback.

### Option 3 — Setup fully manuel (experts, custom iOS version)

Si tu es sur un build iOS différent du nôtre, tu dois signer TON passd spécifique. Voir [SETUP_MANUAL.md](SETUP_MANUAL.md) (à créer).

Résumé :
1. Pull TON `/System/Library/PrivateFrameworks/PassKitCore.framework/passd`
2. Extract entitlements, prep (strip seatbelt, add `platform-application` + `get-task-allow`)
3. arm64e → arm64 patch (byte@offset 8 = 0)
4. `ldid -S` then `ct_bypass_linux` (ou `fastPathSign` on-device)
5. Deploy to `/var/jb/System/Library/SysBins/PassKitCore.framework/passd`
6. Override plist to `/var/jb/Library/LaunchDaemons/com.apple.passd.plist`
7. Write PassKit preferences (les 8 clés listed ci-dessous)
8. Reload launchd + reboot + re-JB

## Si safe mode après setup Apple Pay

```bash
# Via SSH (iPhone doit booter quand même, safe mode permet SSH)
sudo bash /var/jb/opt/watchpair11/rollback-applepay.sh

# Reboot iPhone + Re-JB
```

Le rollback restaure passd native + efface les override plists + restore tes anciennes PassKit prefs depuis backup auto.

## PassKit preferences (clés magiques)

Le script les écrit automatiquement dans `/var/mobile/Library/Preferences/com.apple.passd.plist`.

> **v7.17 fix** ([issue #2](https://github.com/plokijuter/WatchPair11/issues/2), credit [@577fkj](https://github.com/577fkj))
> Trois clés CFPreferences/NSUserDefaults divergent du nom du symbole `extern NSString * const` exporté par PassKitCore. Le script écrit désormais **les deux versions** (legacy + corrigée) :
> - `PKIsUserPropertyOverrideEnabled` → en réalité `PKIsUserPropertyOverrideEnabledKey`
> - `PKDeveloperLoggingEnabled` → en réalité `PKDeveloperLogging`
> - `PKShowFakeRemoteCredentials` → en réalité `PKShowFakeRemoteCredentialsKey`
>
> Note : `PKIsUserPropertyOverrideEnabled` et `PKShowFakeRemoteCredentials` sont en plus gatés par `os_variant_has_internal_ui_6("com.apple.wallet")` — sur build retail, ces deux fonctions retournent toujours `false` même avec la bonne clé. Voir issue #2 pour les screenshots de désassemblage.

| Clé (corrigée) | Valeur | Effet |
|----------------|--------|-------|
| `PKIsUserPropertyOverrideEnabledKey` | true | Master gate des overrides PassKit (gated `internal_ui`) |
| `PKBypassCertValidation` | true | Skip validation certs Apple |
| `PKBypassStockholmRegionCheck` | true | Skip region check (Stockholm = Apple Pay codename) |
| `PKBypassImmoTokenCountCheck` | true | Skip immobilier token count |
| `PKDeveloperLogging` | true | Logs détaillés |
| `PKClientHTTPHeaderHardwarePlatformOverride` | iPhone15,3 | Header spoof platform |
| `PKClientHTTPHeaderOSPartOverride` | iPhone OS 17.0 | Header spoof OS |
| `PKShowFakeRemoteCredentialsKey` | true | Watch affiche carte comme validée (gated `internal_ui`) |

## Credits / Remerciements

- **[577fkj/WatchFix](https://github.com/577fkj/WatchFix)** (GPLv3) : Source pour hooks APSSupport/AppsSupport/IDSUTun
- **[@577fkj](https://github.com/577fkj)** : Reverse engineering [issue #2](https://github.com/plokijuter/WatchPair11/issues/2) — identification des vraies clés CFPreferences PassKit (v7.17 fix)
- **[opa334/ChOma](https://github.com/opa334/ChOma)** (MIT) : Mach-O parsing + CoreTrust CVE-2023-41991. **Nous avons porté `ct_bypass` Linux avec support arm64e** (contribution originale)
- **[opa334/TrollStore](https://github.com/opa334/TrollStore)** : fastPathSign + pattern injection
- **[verygenericname/nathanlr](https://github.com/verygenericname/nathanlr)** : Le jailbreak sur iOS 16.5.1 - 16.7.x
- **[verygenericname/nathanlr_hooks](https://github.com/verygenericname/nathanlr_hooks)** : launchdhook / xpcproxyhook
- **[SerotoninApp/Serotonin](https://github.com/SerotoninApp/Serotonin)** : Base launchdhook
- **Legizmo Moonstone (lunotech11)** : Référence commerciale

## Architecture technique

Le tweak WatchPair11.dylib injecte dans 5 processus iOS 16 (via MobileSubstrate filter plist) :

- **SpringBoard** : spoof iOS 18.5, CFPreferences pairing, PassKit compat
- **bluetoothd** : BLE drain fix (block NearbyAction type 0x00)
- **appconduitd** : AppsSupport hook (MobileSMS supplemental mapping)
- **installd** : MIEmbeddedWatchBundle version spoof (watchOS 11.9999)
- **passd** (v7.15+ via SysBins) : Apple Pay provisioning hooks + NRDevice productType spoof

Les daemons `apsd` et `identityservicesd` sont **intentionnellement non-injectés** :
- `apsd` : cassait push notifs 3rd-party
- `identityservicesd` : SIGSEGV dans Logos ctor

## Contribution originale : ct_bypass_linux arm64e support

Le port Linux de ChOma's `ct_bypass` supportait originalement seulement arm64. Nous avons ajouté le support arm64e, nécessaire pour signer les binaires iPhone 14/15 (arm64e PAC).

Fichiers dans `ctbypass_artifacts/` :

- `build_linux_ctbp.sh` : script build
- `main_linux.c` : wrapper avec fix missing `#include "Host.h"` (sans ça, return pointer truncated 64→32 bit → segfault)
- `coretrust_bug_libplist_patch.c` : version utilisant libplist au lieu de CoreFoundation
- `compat_headers/` : shims Apple (mach, mach-o, libkern, CommonCrypto, sys/sysctl)
- Host.c fallback (patched inline dans build) pour Linux cross-compile :
  ```c
  if (sysctlbyname("hw.cputype", ...) == -1) {
      *cputype = 0x100000c;   // CPU_TYPE_ARM64
      *cpusubtype = 2;        // CPU_SUBTYPE_ARM64E
      return 0;
  }
  ```

Le `ct_bypass_linux` résultant peut signer tout binaire iOS arm64/arm64e avec TeamID T8ALTGMVXN via CVE-2023-41991 depuis un host Linux sans Mac.

## Changelog

- **v7.17** (actuel) : **Fix clés PassKit** ([issue #2](https://github.com/plokijuter/WatchPair11/issues/2), credit [@577fkj](https://github.com/577fkj))
  - 3 clés CFPreferences/NSUserDefaults corrigées : `PKIsUserPropertyOverrideEnabledKey`, `PKDeveloperLogging`, `PKShowFakeRemoteCredentialsKey`
  - Écriture **additive** : legacy + corrigé (zéro risque de régression)
  - Documentation du gate `os_variant_has_internal_ui_6("com.apple.wallet")` qui bloque 2 des 3 fonctions sur builds retail
  - Setup install repo Cydia/Sileo/Zebra : `https://plokijuter.github.io/WatchPair11/`
- **v7.16 + installer app** : **Home-screen installer app** one-tap setup
  - `installer-app/` : app iOS autonome (Theos application_modern, UIKit)
  - Embed toutes les ressources (`WatchPair11.dylib`, `passd_signed`, overrides, prefs)
  - 3 boutons : Install Tweak / Install Apple Pay / Rollback — aucun SSH requis
  - `sudo_spawn_root` pour élévation depuis user app
  - Live log UITextView + status refresh + confirm dialogs
- **v7.16** : **Scripts automation Apple Pay setup** + cleaner postinst
  - `scripts/setup-applepay.sh` : script installation Apple Pay avec sanity checks + backup
  - `scripts/rollback-applepay.sh` : revert complet en cas de problème
  - Bundled dans `.deb` sous `/var/jb/opt/watchpair11/`
  - Postinst propose 3 options (auto via env var, manuel, script standalone)
- **v7.15** : **🏆 Apple Pay Watch provisioning works!** Combinaison :
  - 5 NPK C gate hooks dans passd
  - PKProductTypeFromNRDevice MSHookFunction → Watch6,14
  - PassKit NSUserDefaults overrides (PKShowFakeRemoteCredentials, etc.)
  - ct_bypass_linux arm64e support (contribution originale)
  - passd SysBins pipeline + override LaunchDaemon plist
- **v7.14** : Narrow productType spoof (avoid break SpringBoard launch)
- **v7.13** : Watch productType spoof Series 10 → Series 8
- **v7.12** : Darwin notifications listener dans SpringBoard pour debug Bridge
- **v7.11** : Minimal NPKCompanionAgent hook
- **v7.10** : posix_spawn hook xpcproxy (abandonné)
- **v7.9** : Surgical NPK hooks dans passd
- **v7.8** : hookPassd dans SpringBoard + Bridge + NPKCompanionAgent
- **v7.7** : NSUserDefaults PassKit override keys
- **v7.6** : Désactive hookAPSSupport (cassait push notifs 3rd-party)
- **v7.4** : Retire identityservicesd du filter (crash Logos ctor)
- **v7.3** : Integration hooks WatchFix
- **v6.9** : Recette initiale validée (SpringBoard + bluetoothd seulement)

## Troubleshooting

### Safe mode après install
```bash
sudo mv /var/jb/Library/MobileSubstrate/DynamicLibraries/WatchPair11.dylib{,.disabled}
sudo mv /var/jb/usr/lib/TweakInject/WatchPair11.dylib{,.disabled}
sudo reboot
```

### Safe mode après Apple Pay setup
```bash
sudo bash /var/jb/opt/watchpair11/rollback-applepay.sh
sudo reboot
```

### Crash logs
- Path : `/var/mobile/Library/Logs/CrashReporter/*.ips`
- Via SSH : `ls -lt /var/mobile/Library/Logs/CrashReporter/ | head -10`
- Via Settings : Privacy & Security → Analytics & Improvements → Analytics Data

### Verify hooks actifs
```bash
# Witnesses (confirment dylib load)
ls -la /var/tmp/wp11_*.txt

# Log en temps réel
tail -f /var/tmp/wp11.log
```

### Apple Pay fonctionne pas
1. Check passd prefs : `cat /var/mobile/Library/Preferences/com.apple.passd.plist` (doit contenir les 8 clés PK*)
2. Check passd witness : `/var/tmp/wp11_passd.txt` doit exister
3. Check passd hooks installés : `grep passd /var/tmp/wp11.log | grep Hooked`
4. Si manque : tu n'as pas fait le setup Apple Pay OU le reboot+re-JB

## Limitations connues

- Testé **uniquement** sur iPhone 14 Pro Max iOS 16.6 build 20G75 + Apple Watch Series 10 watchOS 11.5
- Si ton iOS build diffère, le `passd_signed` bundled peut ne pas fonctionner → setup manuel nécessaire
- Si Watch ne répond pas physiquement au NFC (terminal paiement), `PKShowFakeRemoteCredentials` n'a fait qu'un bypass UI — tester à un vrai terminal

## Installation depuis les sources

```bash
make package
# → packages/com.watchpair11.tweak_*.deb
```

### Via SSH

```bash
scp -P 8056 packages/*.deb mobile@127.0.0.1:/var/mobile/Documents/
ssh -p 8056 mobile@127.0.0.1 "echo '<password>' | sudo -S dpkg -i /var/mobile/Documents/com.watchpair11.tweak_*.deb"
```

Après install, **rejailbreak** (relancer nathanlr) pour activer tous les hooks SysBins.
