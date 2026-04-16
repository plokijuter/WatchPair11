# WatchPair11

Tweak jailbreak pour jumeler une Apple Watch **watchOS 11.5** avec un iPhone **iOS 16** via le jailbreak [nathanlr](https://github.com/verygenericname/nathanlr).

## Requis

- iPhone avec **iOS 16.5 - 16.7** jailbreaké avec **nathanlr**
- [Theos](https://theos.dev/) configuré avec le SDK iOS 16
- Apple Watch sous **watchOS 11.x**

## Installation (depuis les sources)

```bash
# Build
make package

# Copier le .deb sur l'iPhone et installer
scp -P 2222 packages/*.deb mobile@127.0.0.1:/tmp/
ssh -p 2222 mobile@127.0.0.1 "sudo dpkg -i /tmp/com.watchpair11.tweak_*.deb"
```

Apres l'installation, **rejailbreak** (relancer nathanlr) pour que le loader soit actif.

## Ce que fait le tweak

| Processus | Hook |
|---|---|
| **bluetoothd** | Bloque `setNearbyActionV2Type:0x00` (BLE adv type 0x14 de watchOS 11.5 non reconnu par iOS 16, cause du drain batterie) |
| **SpringBoard** | Spoof CFPreferences (`maxPairingCompatibilityVersion=99`), spoof `operatingSystemVersion` -> 18.5.0 |
| **Daemons IDS** (identityservicesd, imagent, apsd...) | `IDSAccount` availability -> YES, `minCompatibilityVersion` -> 1 |
| **Tous les process filtres** | `NRDevice.compatibilityState` -> COMPATIBLE, prevention du depairage force |

### Process filtres (WatchPair11.plist)

SpringBoard, bluetoothd, Bridge, companionproxyd, terminusd, pairedsyncd, nanoregistrylaunchd, appconduitd, installd, identityservicesd, apsd, imagent, nptocompaniond, passd

### Ce que le tweak ne fait PAS

- Pas d'injection dans nanoregistryd (cause des boot loops + Alloy/IDS casse)
- Pas de force-state hooks (`isAsleep=NO`, `isConnected=YES`) - casse la connexion Watch

## Structure

```
Tweak.xm                  # Source principal (~1600 lignes)
WP11Loader.c              # Loader qui remplace libTS2JailbreakEnv.dylib
WatchPair11.plist          # Filtre MobileSubstrate (process cibles)
Makefile                   # Build Theos (rootless)
wp11bridge/                # Daemon bridge Alloy IDS topics
  main.m                   # Enregistre les Alloy topics manquants sur iOS 16
```

## Credits

- [watched](https://github.com/34306/watched) - point de depart (bypass NanoRegistry via plist)
- [Legizmo](https://chariz.com/buy/legizmo-moonstone) - architecture de reference (Hephaestus plugins)
- [nathanlr](https://github.com/verygenericname/nathanlr) - jailbreak iOS 16
- [ChOma](https://github.com/opa334/ChOma) - ct_bypass pour la signature CoreTrust
