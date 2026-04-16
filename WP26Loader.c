/*
 * WP26Loader - Remplace libTS2JailbreakEnv.dylib
 *
 * Installation :
 *   1. Renommer /var/jb/usr/lib/libTS2JailbreakEnv.dylib -> libTS2JailbreakEnv_orig.dylib
 *   2. Copier ce dylib comme /var/jb/usr/lib/libTS2JailbreakEnv.dylib
 *   3. Rejailbreak (relancer nathanlr)
 *
 * Ce dylib :
 *   1. Charge l'original libTS2JailbreakEnv_orig.dylib (pour que rien ne casse)
 *   2. Charge TweakLoader.dylib dans les daemons qui en ont besoin
 */

#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

extern const char *getprogname(void);

__attribute__((constructor))
static void wp26loader_init(void) {
    // 1. Charger l'original libTS2JailbreakEnv
    dlopen("/var/jb/usr/lib/libTS2JailbreakEnv_orig.dylib", RTLD_LAZY);

    // 2. Si TweakLoader est déjà chargé, on a fini
    void *handle = dlopen("/var/jb/usr/lib/TweakLoader.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (handle) return;

    // 3. Vérifier si on est dans un processus cible
    const char *procName = getprogname();
    if (!procName) return;

    const char *targets[] = {
        "identityservicesd", "imagent", "apsd",
        "nanoregistryd", "companionproxyd", "terminusd",
        "pairedsyncd", "nptocompaniond", "appconduitd",
        "Bridge", "passd", "installd",
        "nanoregistrylaunchd",
        NULL
    };

    for (int i = 0; targets[i]; i++) {
        if (strcmp(procName, targets[i]) == 0) {
            // Charger TweakLoader
            dlopen("/var/jb/usr/lib/TweakLoader.dylib", RTLD_LAZY);

            // Fichier témoin
            char path[256];
            snprintf(path, sizeof(path), "/var/tmp/wp26_%s.txt", procName);
            FILE *f = fopen(path, "w");
            if (f) { fprintf(f, "loaded\n"); fclose(f); }
            return;
        }
    }
}
