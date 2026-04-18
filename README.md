# WatchPair11

## Description

WatchPair11 est un tweak iOS pour [nathanlr](https://github.com/verygenericname/nathanlr) (iOS 16.6) qui permet de jumeler une Apple Watch **watchOS 11.5** avec un iPhone **iOS 16**. Bypass NanoRegistry + MobileAsset + CFPreferences flush, avec fix drain batterie BLE et support iMessage relay via Watch.

> **Ce repo n'est pas activement maintenu.** C'est un projet personnel qui repond a un besoin specifique (garder iOS 16 avec une Watch recente). Les issues et PRs seront lus mais pas forcement traites rapidement. Utilisez a vos risques.

## Fonctionnalites qui MARCHENT

- Pairing watchOS 11.5 <-> iOS 16 (iPhone 14 Pro Max teste)
- BLE drain fix (batterie normale, bloc 0x00 BLE type)
- Apple Messages (iMessage) sur Watch : envoi + reception + notifications
- Toutes les notifications 3rd-party arrivent sur Watch (Facebook Messenger, WhatsApp, etc.)
- Reponse aux notifications depuis Watch (via UI watchOS generique)
- Pairing stable apres reboot + re-JB

## Fonctionnalites qui NE MARCHENT PAS

- **Apple Pay "Ajouter carte"** : bloque cote serveur Apple. Apple refuse le provisioning de cartes Watch sur combinaison incompatible iOS 16 + watchOS 11.5. Pas fixable par un tweak local puisque la validation est faite sur les serveurs Apple.
- **Icone Facebook Messenger sur ecran d'accueil Watch** : Facebook a retire son app Watch depuis 2018. L'app iPhone Messenger ne contient plus de bundle watchOS. Les notifications arrivent quand meme (via systeme iOS).

## Prerequis

- iPhone supporte par nathanlr (iPhone 14 Pro Max teste, iOS 16.5.1 - 16.7.x sur A15/A16)
- nathanlr jailbreak installe (https://github.com/verygenericname/nathanlr)
- Sileo ou autre package manager

## Installation

1. Telecharge le `.deb` depuis [Releases](https://github.com/plokijuter/WatchPair11/releases)
2. Installe via Sileo (Ouvre `.deb` avec Sileo)
3. Respring
4. (La premiere fois) Pair ta Apple Watch watchOS 11.5 normalement

## Credits / Remerciements

Ce projet n'aurait pas ete possible sans le travail de :

- **[577fkj/WatchFix](https://github.com/577fkj/WatchFix)** (GPLv3) : Source d'inspiration pour les hooks `APSSupport`, `AppsSupport`, `IDSUTun`. Le code original de ces hooks vient de WatchFix adapte pour notre contexte nathanlr.
- **[opa334/ChOma](https://github.com/opa334/ChOma)** (MIT) : Bibliotheque de parsing Mach-O + exploit CoreTrust CVE-2023-41991. Nous avons porte `ct_bypass` vers Linux/WSL (remplacant CoreFoundation par libplist) pour permettre la signature des binaires daemon hors de l'iPhone.
- **[opa334/TrollStore](https://github.com/opa334/TrollStore)** : Source de `fastPathSign` (integration ChOma pour signing) + pattern d'injection.
- **[verygenericname/nathanlr](https://github.com/verygenericname/nathanlr)** : Le jailbreak semi-tethered qui permet tout ce projet sur iOS 16.5.1 - 16.7.x A15/A16. Merci pour le support open-source.
- **[verygenericname/nathanlr_hooks](https://github.com/verygenericname/nathanlr_hooks)** : Les hooks `launchd`/`generalhook`/`xpcproxy` qui permettent l'injection dans SysBins.
- **[SerotoninApp/Serotonin](https://github.com/SerotoninApp/Serotonin)** : Base de `launchdhook` (csops CS_PLATFORM_BINARY force).
- **[Dopamine / opa334](https://github.com/opa334/Dopamine)** : Reference pour `systemhook` et `jbctl trustcache add` (meme si non portable sur nathanlr).
- **Legizmo Moonstone (lunotech11)** : Reference commerciale, a inspire l'approche technique et les classes cibles `ACXAvailableApplicationManager`, `MIEmbeddedWatchBundle`, `APSProxyClient`, `IDSUTunControlMessage_Hello`.

## Architecture technique

Le tweak injecte dans 4 processus iOS 16 :

- **SpringBoard** : spoof version iOS 18.5, hook CFPreferences pairing compatibility, PassKit compat
- **bluetoothd** : BLE drain fix (block NearbyAction type 0x00)
- **appconduitd** : `AppsSupport` hook (MobileSMS supplemental mapping)
- **installd** : `MIEmbeddedWatchBundle` version spoof (watchOS 11.9999)

Les 2 daemons `apsd` et `identityservicesd` sont **intentionnellement non-injectes** :

- `apsd` : hook APSSupport cassait les push notifs 3rd-party (v7.6 revert)
- `identityservicesd` : hook IMService causait SIGSEGV dans Logos ctor (v7.4 revert)

## Limitations connues

- Tweak developpe sur iPhone 14 Pro Max iOS 16.6 + Apple Watch 6 watchOS 11.5. Autres combinaisons non testees.
- Apple Pay fonctionnel sur les cartes deja provisionnees avant pairing iOS 16/watchOS 11.5. Ajouter une NOUVELLE carte = bloque server-side.
- watchOS updates via iPhone pairing ne fonctionneront pas (iOS 16 ne supporte pas watchOS 11+ officiellement).

## Source du ct_bypass_linux

Le sous-dossier `ctbypass_artifacts/` contient :

- `ct_bypass_linux` : binaire Linux x86_64 qui signe des Mach-O iOS arm64 avec bypass CoreTrust
- `build_linux_ctbp.sh` : script build
- `compat_headers/` : shims Apple (mach, mach-o, libkern, CommonCrypto)
- `coretrust_bug_libplist_patch.c` : version patched de `coretrust_bug.c` utilisant libplist au lieu de CoreFoundation
- `main_linux.c` : wrapper minimal pour Linux host
- `prepare_daemon.sh` : pipeline complet (patch arm64 + ldid sign + ct_bypass)

Ceci permet de signer n'importe quel daemon iOS depuis un host Linux sans Mac.

## Changelog

- **v7.6** (actuel) : Desactive `hookAPSSupport` (cassait push notifs 3rd-party)
- **v7.4** : Retire `identityservicesd` du filter (crash Logos ctor)
- **v7.3** : Integration hooks WatchFix (APSSupport, AppsSupport, IDSUTun)
- **v6.9** : Recette initiale validee (SpringBoard + bluetoothd seulement)

## Installation depuis les sources

```bash
make package
```

Apres l'installation, **rejailbreak** (relancer nathanlr) pour que le loader soit actif.

### Via SSH

```bash
scp -P 2222 *.deb mobile@127.0.0.1:/tmp/
ssh -p 2222 mobile@127.0.0.1 "sudo dpkg -i /tmp/com.watchpair11.tweak_*.deb"
```
