#!/bin/bash
# WP11Loader - Script d'installation pour nathanlr
#
# Ce script remplace libTS2JailbreakEnv.dylib par notre wrapper
# qui charge l'original + force TweakLoader dans les daemons Watch
#
# IMPORTANT: Après installation, il faut REJAILBREAK (relancer nathanlr)

ORIG="/var/jb/usr/lib/libTS2JailbreakEnv.dylib"
BACKUP="/var/jb/usr/lib/libTS2JailbreakEnv_orig.dylib"
LOADER_SRC="/var/jb/Library/MobileSubstrate/DynamicLibraries/WP11Loader.dylib"

# Vérifier que le fichier original existe
if [ ! -f "$ORIG" ]; then
    echo "[WP11] ERREUR: $ORIG n'existe pas"
    echo "[WP11] Ce script est pour le jailbreak nathanlr uniquement"
    exit 1
fi

# Backup de l'original (seulement si pas déjà fait)
if [ ! -f "$BACKUP" ]; then
    echo "[WP11] Backup: $ORIG -> $BACKUP"
    cp "$ORIG" "$BACKUP"
else
    echo "[WP11] Backup existe déjà: $BACKUP"
fi

# Copier notre loader comme WP11Loader.dylib
cp "$LOADER_SRC" /var/jb/usr/lib/WP11Loader.dylib 2>/dev/null

# Remplacer libTS2JailbreakEnv.dylib par notre wrapper
echo "[WP11] Remplacement: $ORIG -> WP11Loader"
cp /var/jb/usr/lib/WP11Loader.dylib "$ORIG"

# Signer le dylib (important pour arm64e)
ldid -S "$ORIG" 2>/dev/null

echo "[WP11] Installation terminée!"
echo "[WP11] IMPORTANT: Vous devez maintenant REJAILBREAK (relancer nathanlr)"
echo "[WP11] Après rejailbreak, les daemons Watch chargeront le tweak"
