# WatchPair11

Tweak jailbreak pour jumeler une Apple Watch **watchOS 11.5** avec un iPhone **iOS 16** via le jailbreak [nathanlr](https://github.com/verygenericname/nathanlr).

Inspire par [Legizmo](https://chariz.com/buy/legizmo-moonstone) (architecture Hephaestus, approche hooks multi-daemons). Ce projet est un effort independant de reverse engineering, pas un fork de Legizmo.

> **Ce repo n'est pas activement maintenu.** C'est un projet personnel qui repond a un besoin specifique (garder iOS 16 avec une Watch recente). Les issues et PRs seront lus mais pas forcement traites rapidement. Utilisez a vos risques.

## Ce qui marche

- Pairing initial watchOS 11.5 <-> iOS 16
- Sync initiale
- Configuration des cadrans depuis l'iPhone
- Pas de depairage force
- Batterie normale (~1.2%/h, pas de drain BLE)
- Notifications push vers la Watch
- Apps Watch natives (Meteo, Minuteur, Alarmes, Boussole...)

## Problemes connus

| Feature | Statut | Detail |
|---|---|---|
| **Messages (iMessage/SMS)** | Partiel | Les messages recus s'affichent sur la Watch. **Envoyer un message depuis la Watch ne fonctionne pas.** |
| **Messenger** | Partiel | L'app Messenger n'apparait pas sur la Watch, mais la reception et la reponse aux messages fonctionnent via les notifications. |
| **Health/Sante** | Non teste | Sync donnees sante potentiellement cassee (necessite injection nanoregistryd, pas possible sans boot loops). |
| **Maps** | Non teste | Navigation Watch -> iPhone potentiellement cassee. |
| **Music sync** | Non teste | Transfert de playlists vers la Watch non verifie. |
| **Install apps** | Non teste | Installation d'apps tierces depuis l'iPhone non verifiee. |
| **Walkie-Talkie** | Non teste | Necessite Alloy topics supplementaires. |

### Pourquoi ces limitations

Le tweak ne peut **pas** s'injecter dans `nanoregistryd` (le daemon central Apple Watch) sans provoquer des boot loops et casser Alloy/IDS. L'injection est bloquee par le sandbox kernel (`trustLevel=0` pour les binaires re-signes au runtime). Seuls les daemons pre-signes par nathanlr au moment du jailbreak (bluetoothd, SpringBoard, installd...) sont hookables.

Les features manquantes (Messages sortants, Messenger) necessiteraient des hooks dans des daemons non injectables ou des Alloy topics que iOS 16 refuse de router pour watchOS 11.5.

## Requis

- iPhone avec **iOS 16.5 - 16.7** jailbreake avec **nathanlr**
- [Theos](https://theos.dev/) configure avec le SDK iOS 16
- Apple Watch sous **watchOS 11.x**

## Installation

```bash
# Build
make package

# Copier le .deb sur l'iPhone (via iproxy USB)
scp -P 2222 packages/*.deb mobile@127.0.0.1:/tmp/

# Installer
ssh -p 2222 mobile@127.0.0.1 "sudo dpkg -i /tmp/com.watchpair11.tweak_*.deb"
```

Apres l'installation, **rejailbreak** (relancer nathanlr) pour que le loader soit actif.

## Comment ca marche

| Processus | Hook |
|---|---|
| **bluetoothd** | Bloque `setNearbyActionV2Type:0x00` — le BLE advertisement type 0x14 de watchOS 11.5 n'est pas reconnu par le parser iOS 16, ce qui causait un drain batterie (flapping asleep/awake toutes les ~5s) |
| **SpringBoard** | Spoof CFPreferences (`maxPairingCompatibilityVersion=99`), spoof `operatingSystemVersion` -> 18.5.0 |
| **Daemons IDS** (identityservicesd, imagent, apsd...) | `IDSAccount` availability -> YES, `minCompatibilityVersion` -> 1 |
| **Tous les process filtres** | `NRDevice.compatibilityState` -> COMPATIBLE, prevention du depairage force |

### Process filtres (WatchPair11.plist)

SpringBoard, bluetoothd, Bridge, companionproxyd, terminusd, pairedsyncd, nanoregistrylaunchd, appconduitd, installd, identityservicesd, apsd, imagent, nptocompaniond, passd

### Ce que le tweak ne fait PAS (et pourquoi)

- **Pas d'injection dans nanoregistryd** — cause des boot loops + casse Alloy/IDS. Le sandbox kernel kill le process re-signe (trustLevel=0).
- **Pas de force-state hooks** (`isAsleep=NO`, `isConnected=YES`) — casse la connexion Watch reelle.

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

- [watched](https://github.com/34306/watched) — point de depart (bypass NanoRegistry via plist)
- [Legizmo](https://chariz.com/buy/legizmo-moonstone) — architecture de reference (plugins Hephaestus par daemon). Si vous cherchez une solution maintenue et complete, achetez Legizmo.
- [nathanlr](https://github.com/verygenericname/nathanlr) — jailbreak iOS 16
- [ChOma](https://github.com/opa334/ChOma) — ct_bypass pour la signature CoreTrust
- [furiousMAC/continuity](https://github.com/furiousMAC/continuity) — documentation des TLV BLE Apple Continuity
