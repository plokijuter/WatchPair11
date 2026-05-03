#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <spawn.h>
#import <signal.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <substrate.h>

// Cross-jailbreak path resolution.
// Under roothide the prefix is randomized per-install (e.g.
// /var/containers/Bundle/Application/.jbroot-<rand16hex>/) so every
// hardcoded "/var/jb/..." literal MUST go through jbroot() at runtime.
// Under nathanlr (rootless) jbroot.h is absent and we fall back to the
// static "/var/jb" prefix.
#if __has_include(<roothide.h>)
#  include <roothide.h>
#  define WP11_JBROOT(p) jbroot(p)
#else
#  define WP11_JBROOT(p) ("/var/jb" p)
#endif

/*
 * WatchPair11 - watchOS 11.5 <-> iOS 16 (nathanlr)
 *
 * v4 bloquait l'unpair côté iPhone, mais la Watch reçoit la VRAIE
 * version iOS (16.x) et se dé-jumèle de SON côté.
 *
 * v5+ ajoute le SPOOFING DE VERSION iOS:
 *   - Hook NSProcessInfo.operatingSystemVersion → 18.5.0
 *   - Hook valueForProperty: pour SystemVersion/MarketingVersion → "18.5"
 *   - Hook NRPairingCompatibilityVersionInfo.systemVersions
 *   - Intercepte la lecture de SystemVersion.plist → ProductVersion spoofé
 *   - Tout ce que v4 faisait déjà
 */

// Version iOS à spoofer (watchOS 11.5 attend iOS 18.x)
// Watch = watchOS 11.5 (22T572), Watch6,10 — requires iOS 18+
#define SPOOFED_IOS_MAJOR 18
#define SPOOFED_IOS_MINOR 5
#define SPOOFED_IOS_PATCH 0
#define SPOOFED_IOS_VERSION_STRING @"18.5"

#define MAX_COMPAT 99
#define MIN_COMPAT 1

// compatibilityState values (inversées depuis les headers NanoRegistry)
// 0 = compatible, 1+ = incompatible
#define COMPAT_STATE_COMPATIBLE 0

extern void CFPreferencesSetValue(CFStringRef key, CFPropertyListRef value,
                                  CFStringRef appID, CFStringRef user, CFStringRef host);
extern Boolean CFPreferencesSynchronize(CFStringRef appID, CFStringRef user, CFStringRef host);

// =====================================================================
// LOGGING dans /var/mobile/Library/Preferences/wp11.log
// Lisible avec Filza
// =====================================================================
#define WP11_LOG_PATH @"/var/tmp/wp11.log"

static void wp11log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss.SSS"];
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *line = [NSString stringWithFormat:@"[%@][%@] %@\n", ts, proc, msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:WP11_LOG_PATH];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:WP11_LOG_PATH contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:WP11_LOG_PATH];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];

}

static void setPref(CFStringRef appID, CFStringRef key, CFPropertyListRef val) {
    CFPreferencesSetValue(key, val, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue(key, val, appID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
}

// =====================================================================
// HOOKS: NRPairingCompatibilityVersionInfo (version checks)
// =====================================================================
static void hookNRVersionInfo(void) {
    dlopen("/System/Library/PrivateFrameworks/NanoRegistry.framework/NanoRegistry", RTLD_LAZY);
    Class cls = NSClassFromString(@"NRPairingCompatibilityVersionInfo");
    if (!cls) return;

    wp11log(@" Hook NRPairingCompatibilityVersionInfo");

    NSArray *noArgSels = @[
        @"maxPairingCompatibilityVersion",
        @"minPairingCompatibilityVersion",
        @"minPairingCompatibilityVersionWithChipID",
        @"minQuickSwitchCompatibilityVersion",
        @"pairingCompatibilityVersion"
    ];
    for (NSString *selName in noArgSels) {
        SEL sel = NSSelectorFromString(selName);
        if (![cls instancesRespondToSelector:sel]) continue;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        BOOL isMax = [selName hasPrefix:@"max"] || [selName isEqualToString:@"pairingCompatibilityVersion"];
        long long val = isMax ? MAX_COMPAT : MIN_COMPAT;
        class_replaceMethod(cls, sel,
            imp_implementationWithBlock(^long long(id self) { return val; }),
            method_getTypeEncoding(m));
    }

    SEL s1 = NSSelectorFromString(@"minPairingCompatibilityVersionForChipID:name:defaultVersion:");
    if ([cls instancesRespondToSelector:s1]) {
        Method m = class_getInstanceMethod(cls, s1);
        if (m) class_replaceMethod(cls, s1,
            imp_implementationWithBlock(^long long(id s, long long c, NSString *n, long long d) { return MIN_COMPAT; }),
            method_getTypeEncoding(m));
    }

    SEL s2 = NSSelectorFromString(@"minPairingCompatibilityVersionForChipID:");
    if ([cls instancesRespondToSelector:s2]) {
        Method m = class_getInstanceMethod(cls, s2);
        if (m) class_replaceMethod(cls, s2,
            imp_implementationWithBlock(^long long(id s, long long c) { return MIN_COMPAT; }),
            method_getTypeEncoding(m));
    }

    SEL s3 = NSSelectorFromString(@"minQuickSwitchPairingCompatibilityVersionForChipID:");
    if ([cls instancesRespondToSelector:s3]) {
        Method m = class_getInstanceMethod(cls, s3);
        if (m) class_replaceMethod(cls, s3,
            imp_implementationWithBlock(^long long(id s, long long c) { return MIN_COMPAT; }),
            method_getTypeEncoding(m));
    }

    SEL s4 = NSSelectorFromString(@"isOverrideActive");
    if ([cls instancesRespondToSelector:s4]) {
        Method m = class_getInstanceMethod(cls, s4);
        if (m) class_replaceMethod(cls, s4,
            imp_implementationWithBlock(^BOOL(id s) { return YES; }),
            method_getTypeEncoding(m));
    }
}

// =====================================================================
// HOOKS: IDSService - débloquer l'envoi de Messages depuis la Watch
// Le service IDS com.apple.madrid a un MinCompatibilityVersion check
// =====================================================================
static void hookIDSService(void) {
    // Charger IDS.framework
    dlopen("/System/Library/PrivateFrameworks/IDS.framework/IDS", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/IDSFoundation.framework/IDSFoundation", RTLD_LAZY);

    // Hook IDSService initWithServiceDictionary: pour forcer MinCompatibilityVersion bas
    Class idsServiceClass = NSClassFromString(@"IDSService");
    if (idsServiceClass) {
        SEL initDictSel = NSSelectorFromString(@"initWithServiceDictionary:");
        if ([idsServiceClass instancesRespondToSelector:initDictSel]) {
            Method m = class_getInstanceMethod(idsServiceClass, initDictSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                typedef id (*OrigInitFunc)(id, SEL, NSDictionary*);

                class_replaceMethod(idsServiceClass, initDictSel,
                    imp_implementationWithBlock(^id(id self, NSDictionary *dict) {
                        NSMutableDictionary *patched = [dict mutableCopy];
                        // Forcer MinCompatibilityVersion à 1
                        if (patched[@"MinCompatibilityVersion"]) {
                            patched[@"MinCompatibilityVersion"] = @(1);
                            wp11log(@"IDSService patched MinCompatibilityVersion -> 1");
                        }
                        return ((OrigInitFunc)origIMP)(self, initDictSel, patched);
                    }),
                    method_getTypeEncoding(m));
                wp11log(@"Hooked IDSService initWithServiceDictionary:");
            }
        }

        // Hook IDSService initWithServiceIdentifier: (variante)
        SEL initIdSel = NSSelectorFromString(@"initWithServiceIdentifier:");
        if ([idsServiceClass instancesRespondToSelector:initIdSel]) {
            Method m = class_getInstanceMethod(idsServiceClass, initIdSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                typedef id (*OrigFunc)(id, SEL, NSString*);

                class_replaceMethod(idsServiceClass, initIdSel,
                    imp_implementationWithBlock(^id(id self, NSString *identifier) {
                        wp11log(@"IDSService init avec identifier: %@", identifier);
                        return ((OrigFunc)origIMP)(self, initIdSel, identifier);
                    }),
                    method_getTypeEncoding(m));
            }
        }
    }

    // Hook IDSServiceProperties pour supprimer les checks de version
    Class idsPropsClass = NSClassFromString(@"IDSServiceProperties");
    if (idsPropsClass) {
        // minCompatibilityVersion -> 1
        SEL minCompatSel = NSSelectorFromString(@"minCompatibilityVersion");
        if ([idsPropsClass instancesRespondToSelector:minCompatSel]) {
            Method m = class_getInstanceMethod(idsPropsClass, minCompatSel);
            if (m) {
                class_replaceMethod(idsPropsClass, minCompatSel,
                    imp_implementationWithBlock(^long long(id self) { return 1; }),
                    method_getTypeEncoding(m));
                wp11log(@"Hooked IDSServiceProperties.minCompatibilityVersion -> 1");
            }
        }
    }

    // Hook IDSAccount - certains checks de compatibilité se font au niveau account
    Class idsAccountClass = NSClassFromString(@"IDSAccount");
    if (idsAccountClass) {
        for (NSString *selName in @[@"isServiceAvailable", @"isActive", @"isEnabled"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([idsAccountClass instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(idsAccountClass, sel);
                if (m) {
                    class_replaceMethod(idsAccountClass, sel,
                        imp_implementationWithBlock(^BOOL(id self) { return YES; }),
                        method_getTypeEncoding(m));
                }
            }
        }
        wp11log(@"Hooked IDSAccount availability methods -> YES");
    }
}

// =====================================================================
// HOOKS: Spoofing de la version iOS envoyée à la Watch
// =====================================================================
static void hookVersionSpoofing(void) {
    // 1. Hook NSProcessInfo.operatingSystemVersion
    //    nanoregistryd utilise ça pour déterminer la version iOS
    Class procInfoClass = [NSProcessInfo class];
    SEL osVerSel = NSSelectorFromString(@"operatingSystemVersion");
    if ([procInfoClass instancesRespondToSelector:osVerSel]) {
        Method m = class_getInstanceMethod(procInfoClass, osVerSel);
        if (m) {
            class_replaceMethod(procInfoClass, osVerSel,
                imp_implementationWithBlock(^NSOperatingSystemVersion(id self) {
                    NSOperatingSystemVersion v;
                    v.majorVersion = SPOOFED_IOS_MAJOR;
                    v.minorVersion = SPOOFED_IOS_MINOR;
                    v.patchVersion = SPOOFED_IOS_PATCH;
                    return v;
                }),
                method_getTypeEncoding(m));
            wp11log(@" Hooked operatingSystemVersion -> %d.%d.%d",
                  SPOOFED_IOS_MAJOR, SPOOFED_IOS_MINOR, SPOOFED_IOS_PATCH);
        }
    }

    // 2. Hook NSProcessInfo.operatingSystemVersionString
    SEL osVerStrSel = NSSelectorFromString(@"operatingSystemVersionString");
    if ([procInfoClass instancesRespondToSelector:osVerStrSel]) {
        Method m = class_getInstanceMethod(procInfoClass, osVerStrSel);
        if (m) {
            class_replaceMethod(procInfoClass, osVerStrSel,
                imp_implementationWithBlock(^NSString *(id self) {
                    return [NSString stringWithFormat:@"Version %d.%d (Build 22F770)",
                            SPOOFED_IOS_MAJOR, SPOOFED_IOS_MINOR];
                }),
                method_getTypeEncoding(m));
            wp11log(@" Hooked operatingSystemVersionString");
        }
    }

    // 3. Hook NSDictionary.dictionaryWithContentsOfFile: pour intercepter SystemVersion.plist
    //    Quand nanoregistryd lit /System/Library/CoreServices/SystemVersion.plist,
    //    on spoofe le ProductVersion
    Method origDictMethod = class_getClassMethod([NSDictionary class],
        @selector(dictionaryWithContentsOfFile:));
    if (origDictMethod) {
        IMP origIMP = method_getImplementation(origDictMethod);
        typedef NSDictionary* (*OrigDictFunc)(id, SEL, NSString*);

        class_replaceMethod(object_getClass([NSDictionary class]),
            @selector(dictionaryWithContentsOfFile:),
            imp_implementationWithBlock(^NSDictionary*(id self, NSString *path) {
                NSDictionary *result = ((OrigDictFunc)origIMP)(self,
                    @selector(dictionaryWithContentsOfFile:), path);
                if (path && [path containsString:@"SystemVersion.plist"]) {
                    NSMutableDictionary *spoofed = [result mutableCopy];
                    spoofed[@"ProductVersion"] = SPOOFED_IOS_VERSION_STRING;
                    spoofed[@"ProductBuildVersion"] = @"22F770";
                    wp11log(@" Spoofed SystemVersion.plist ProductVersion -> %@",
                          SPOOFED_IOS_VERSION_STRING);
                    return [spoofed copy];
                }
                return result;
            }),
            method_getTypeEncoding(origDictMethod));
        wp11log(@" Hooked dictionaryWithContentsOfFile: (SystemVersion.plist spoof)");
    }
}

// =====================================================================
// HOOKS: NRDevice / NRMutableDevice (post-pairing compatibility state)
// =====================================================================
static void hookNRDevice(void) {
    // Hook NRDevice
    Class deviceClass = NSClassFromString(@"NRDevice");
    Class mutableClass = NSClassFromString(@"NRMutableDevice");

    NSMutableArray *classes = [NSMutableArray array];
    if (deviceClass) [classes addObject:deviceClass];
    if (mutableClass) [classes addObject:mutableClass];

    // Hook compatibilityState -> toujours 0 (compatible)
    for (Class cls in classes) {

        SEL compatSel = NSSelectorFromString(@"compatibilityState");
        if ([cls instancesRespondToSelector:compatSel]) {
            Method m = class_getInstanceMethod(cls, compatSel);
            if (m) {
                class_replaceMethod(cls, compatSel,
                    imp_implementationWithBlock(^long long(id self) {
                        return (long long)COMPAT_STATE_COMPATIBLE;
                    }),
                    method_getTypeEncoding(m));
                wp11log(@" Hooked %@.compatibilityState -> COMPATIBLE", NSStringFromClass(cls));
            }
        }

        // Hook isCompatible / isPairingCompatible si ça existe
        for (NSString *selName in @[@"isCompatible", @"isPairingCompatible"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([cls instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(cls, sel);
                if (m) {
                    class_replaceMethod(cls, sel,
                        imp_implementationWithBlock(^BOOL(id self) { return YES; }),
                        method_getTypeEncoding(m));
                    wp11log(@" Hooked %@.%@ -> YES", NSStringFromClass(cls), selName);
                }
            }
        }
    }

    // Hook NRPairedDeviceRegistry methods
    Class regClass = NSClassFromString(@"NRPairedDeviceRegistry");
    if (regClass) {
        // canCommunicateOnRegularServicesWithDevice: -> YES
        SEL canCommSel = NSSelectorFromString(@"canCommunicateOnRegularServicesWithDevice:");
        if ([regClass instancesRespondToSelector:canCommSel]) {
            Method m = class_getInstanceMethod(regClass, canCommSel);
            if (m) {
                class_replaceMethod(regClass, canCommSel,
                    imp_implementationWithBlock(^BOOL(id self, id device) { return YES; }),
                    method_getTypeEncoding(m));
                wp11log(@" Hooked canCommunicateOnRegularServicesWithDevice: -> YES");
            }
        }

        // canCommunicateOnRegularServicesWithActiveWatch -> YES
        SEL canCommActiveSel = NSSelectorFromString(@"canCommunicateOnRegularServicesWithActiveWatch");
        if ([regClass instancesRespondToSelector:canCommActiveSel]) {
            Method m = class_getInstanceMethod(regClass, canCommActiveSel);
            if (m) {
                class_replaceMethod(regClass, canCommActiveSel,
                    imp_implementationWithBlock(^BOOL(id self) { return YES; }),
                    method_getTypeEncoding(m));
                wp11log(@" Hooked canCommunicateOnRegularServicesWithActiveWatch -> YES");
            }
        }
    }

    // Hook valueForProperty: sur NRDevice pour intercepter CompatibilityState
    if (deviceClass) {
        SEL valPropSel = NSSelectorFromString(@"valueForProperty:");
        if ([deviceClass instancesRespondToSelector:valPropSel]) {
            Method m = class_getInstanceMethod(deviceClass, valPropSel);
            if (m) {
                IMP origIMP = method_getImplementation(m);
                typedef id (*OrigFunc)(id, SEL, id);

                class_replaceMethod(deviceClass, valPropSel,
                    imp_implementationWithBlock(^id(id self, id property) {
                        id result = ((OrigFunc)origIMP)(self, valPropSel, property);
                        // Si la propriété est CompatibilityState, retourner compatible
                        if ([property isKindOfClass:[NSString class]]) {
                            NSString *prop = (NSString *)property;
                            if ([prop containsString:@"ompatibilityState"] ||
                                [prop containsString:@"ompatibility"]) {
                                return @(COMPAT_STATE_COMPATIBLE);
                            }
                            // Spoofer la version iOS rapportée via les propriétés NRDevice
                            if ([prop containsString:@"SystemVersion"] ||
                                [prop containsString:@"MarketingVersion"]) {
                                wp11log(@" Spoofed NRDevice property %@ -> %@", prop, SPOOFED_IOS_VERSION_STRING);
                                return SPOOFED_IOS_VERSION_STRING;
                            }
                            if ([prop containsString:@"MaxPairingCompatibilityVersion"]) {
                                return @(MAX_COMPAT);
                            }
                        }
                        return result;
                    }),
                    method_getTypeEncoding(m));
                wp11log(@" Hooked NRDevice.valueForProperty: (intercepte CompatibilityState)");
            }
        }
    }
}

// v7.14: NARROW Watch productType spoof — runs ONLY in passd (Apple Pay preflight path)
// This avoids breaking SpringBoard/Bridge launch which other processes need
__attribute__((unused))
static void hookPassdModelSpoof(void) {
    // Hook NRDevice.valueForProperty: ONLY in passd context
    // Spoof ProductType to Watch6,14 (Series 8, native iOS 16 support)
    Class NRDev = NSClassFromString(@"NRDevice");
    if (!NRDev) {
        wp11log(@" [passd-model] NRDevice not loaded");
        return;
    }
    SEL valPropSel = NSSelectorFromString(@"valueForProperty:");
    if (![NRDev instancesRespondToSelector:valPropSel]) return;
    Method m = class_getInstanceMethod(NRDev, valPropSel);
    IMP origIMP = method_getImplementation(m);
    typedef id (*OrigFunc)(id, SEL, id);
    class_replaceMethod(NRDev, valPropSel,
        imp_implementationWithBlock(^id(id self, id property) {
            id result = ((OrigFunc)origIMP)(self, valPropSel, property);
            if ([property isKindOfClass:[NSString class]]) {
                NSString *prop = (NSString *)property;
                if ([prop containsString:@"ProductType"] || [prop isEqualToString:@"ProductType"]) {
                    if ([result isKindOfClass:[NSString class]] &&
                        [(NSString *)result hasPrefix:@"Watch"]) {
                        wp11log(@" [passd-model] Watch productType %@ → Watch6,14", result);
                        return @"Watch6,14";
                    }
                }
            }
            return result;
        }),
        method_getTypeEncoding(m));
    wp11log(@" [passd-model] Hooked NRDevice.valueForProperty: for productType spoof");

    // v7.15: Hook the PRIMARY PassKit productType extractor used by all Apple Pay checks
    void *pkc = dlopen("/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore", RTLD_LAZY);
    if (pkc) {
        void *sym = dlsym(pkc, "PKProductTypeFromNRDevice");
        wp11log(@" [passd-model] PKProductTypeFromNRDevice sym=%p", sym);
        if (sym) {
            static NSString *(*orig_tmp)(id) = NULL;
            // Use block-style replacement via MSHookFunction
            MSHookFunction(sym, (void *)(^NSString *(id dev) {
                NSString *o = orig_tmp ? orig_tmp(dev) : nil;
                if (o && [o hasPrefix:@"Watch"]) {
                    wp11log(@" [PK-model] PKProductTypeFromNRDevice %@ → Watch6,14", o);
                    return @"Watch6,14";
                }
                return o;
            }), (void **)&orig_tmp);
            wp11log(@" [passd-model] Hooked PKProductTypeFromNRDevice");
        }
    }
}

// =====================================================================
// HOOKS: Bloquer les notifications d'unpair forcé
// =====================================================================
static void hookUnpairPrevention(void) {
    Class regClass = NSClassFromString(@"NRPairedDeviceRegistry");
    if (!regClass) return;

    // Hook retriggerUnpairInfoDialog -> NOP (C'EST ÇA qui cause le dé-jumelage)
    for (NSString *selName in @[@"retriggerUnpairInfoDialog",
                                 @"xpcRetriggerUnpairInfoDialogWithBlock:",
                                 @"_triggerUnpairInfoDialog",
                                 @"_retriggerUnpairInfoDialog",
                                 @"triggerUnpairInfoDialogForDevice:",
                                 @"showUnpairInfoDialog"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([regClass instancesRespondToSelector:sel]) {
            Method m = class_getInstanceMethod(regClass, sel);
            if (m) {
                unsigned int argCount = method_getNumberOfArguments(m);
                if (argCount == 2) {
                    class_replaceMethod(regClass, sel,
                        imp_implementationWithBlock(^(id self) {
                            wp11log(@" BLOQUÉ retriggerUnpairInfoDialog");
                        }),
                        method_getTypeEncoding(m));
                } else if (argCount == 3) {
                    class_replaceMethod(regClass, sel,
                        imp_implementationWithBlock(^(id self, id arg1) {
                            wp11log(@" BLOQUÉ %@", selName);
                        }),
                        method_getTypeEncoding(m));
                }
                wp11log(@" Installé bloqueur: %@", selName);
            }
        }
    }

    // Hook unpairDevice: / unpairAllDevices / obliterateDevice: -> NOP
    for (NSString *selName in @[@"unpairDevice:", @"unpairAllDevices",
                                 @"obliterateDevice:", @"unpairDevice:withOptions:"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([regClass instancesRespondToSelector:sel]) {
            Method m = class_getInstanceMethod(regClass, sel);
            if (m) {
                const char *encoding = method_getTypeEncoding(m);
                // Compter les arguments pour savoir quelle block utiliser
                unsigned int argCount = method_getNumberOfArguments(m);
                if (argCount == 2) { // self + _cmd seulement
                    class_replaceMethod(regClass, sel,
                        imp_implementationWithBlock(^(id self) {
                            wp11log(@" BLOQUÉ: %@ (unpair empêché)", selName);
                        }),
                        encoding);
                } else if (argCount == 3) { // self + _cmd + 1 arg
                    class_replaceMethod(regClass, sel,
                        imp_implementationWithBlock(^(id self, id arg1) {
                            wp11log(@" BLOQUÉ: %@ (unpair empêché)", selName);
                        }),
                        encoding);
                } else if (argCount == 4) { // self + _cmd + 2 args
                    class_replaceMethod(regClass, sel,
                        imp_implementationWithBlock(^(id self, id arg1, id arg2) {
                            wp11log(@" BLOQUÉ: %@ (unpair empêché)", selName);
                        }),
                        encoding);
                }
                wp11log(@" Installé bloqueur unpair: %@", selName);
            }
        }
    }
}

// =====================================================================
// HOOKS: PassKit / NanoPasses - Sync Apple Pay vers la Watch
// =====================================================================
static void hookPassKit(void) {
    // Charger les frameworks PassKit
    dlopen("/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/NanoPasses.framework/NanoPasses", RTLD_LAZY);

    // === Hook PKDeviceCompatibility / PKPaymentDeviceCompatibility ===
    // Ces classes vérifient la compatibilité du device pour Apple Pay
    for (NSString *className in @[@"PKDeviceCompatibility",
                                    @"PKPaymentDeviceCompatibility",
                                    @"PKPaymentService"]) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;

        // Lister les méthodes qui contiennent "compatible", "supported", "available"
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(object_getClass(cls), &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if ([selName containsString:@"isCompatible"] ||
                [selName containsString:@"isSupported"] ||
                [selName containsString:@"canProvision"] ||
                [selName containsString:@"supportsPasses"]) {
                wp11log(@"PassKit class method: +[%@ %@]", className, selName);
            }
        }
        if (methods) free(methods);

        // Méthodes d'instance aussi
        methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if ([selName containsString:@"isCompatible"] ||
                [selName containsString:@"isSupported"] ||
                [selName containsString:@"canProvision"] ||
                [selName containsString:@"supportsPasses"]) {
                wp11log(@"PassKit instance method: -[%@ %@]", className, selName);
            }
        }
        if (methods) free(methods);
    }

    // === Hook PKRemotePaymentPassManager ===
    // Gère le provisioning des cartes sur les devices distants (Watch)
    Class remotePassMgr = NSClassFromString(@"PKRemotePaymentPassManager");
    if (remotePassMgr) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(remotePassMgr, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            // Log toutes les méthodes pour diagnostic
            if ([selName containsString:@"compat"] ||
                [selName containsString:@"version"] ||
                [selName containsString:@"provision"] ||
                [selName containsString:@"verify"] ||
                [selName containsString:@"activate"] ||
                [selName containsString:@"eligible"]) {
                wp11log(@"PKRemotePaymentPassManager: %@", selName);
            }
        }
        if (methods) free(methods);
    }

    // === Hook PKPassLibrary - vérifications de compatibilité Watch ===
    Class passLibClass = NSClassFromString(@"PKPassLibrary");
    if (passLibClass) {
        // canAddPaymentPassForSecureElementIdentifier:... checks si on peut ajouter
        // sur un SE distant (Watch). Force YES.
        for (NSString *selName in @[@"canAddPaymentPassForSecureElementIdentifier:",
                                     @"remoteSecureElementAvailable",
                                     @"isPaymentPassActivationAvailable",
                                     @"remotePaymentPassesAvailable",
                                     @"remoteSecureElementIdentifiers"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([passLibClass instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(passLibClass, sel);
                if (m) {
                    // Vérifier le type de retour
                    const char *retType = method_copyReturnType(m);
                    if (retType && retType[0] == 'B') { // BOOL
                        class_replaceMethod(passLibClass, sel,
                            imp_implementationWithBlock(^BOOL(id self) {
                                wp11log(@"PKPassLibrary.%@ -> YES (forced)", selName);
                                return YES;
                            }),
                            method_getTypeEncoding(m));
                        wp11log(@"Hooked PKPassLibrary.%@ -> YES", selName);
                    }
                    free((void*)retType);
                }
            }
        }
    }

    // === Hook NPKCompanionAgentConnection / NanoPasses sync ===
    // C'est le pont principal pour sync les passes vers la Watch
    for (NSString *className in @[@"NPKCompanionAgentConnection",
                                    @"NPKPassLibrary",
                                    @"NPKCompanionPassManager"]) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;

        wp11log(@"NanoPasses: trouvé %@", className);

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if ([selName containsString:@"compat"] ||
                [selName containsString:@"version"] ||
                [selName containsString:@"supported"] ||
                [selName containsString:@"available"] ||
                [selName containsString:@"eligible"] ||
                [selName containsString:@"provision"] ||
                [selName containsString:@"verify"] ||
                [selName containsString:@"activate"]) {
                wp11log(@"NanoPasses method: -[%@ %@]", className, selName);
            }
        }
        if (methods) free(methods);
    }

    // === Hook PKPaymentWebServiceContext / PKPaymentVerificationController ===
    // Gère la vérification des cartes et la propagation du statut
    Class verifyCtrl = NSClassFromString(@"PKPaymentVerificationController");
    if (verifyCtrl) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(verifyCtrl, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if ([selName containsString:@"complet"] ||
                [selName containsString:@"verif"] ||
                [selName containsString:@"pass"] ||
                [selName containsString:@"device"]) {
                wp11log(@"PKPaymentVerificationController: %@", selName);
            }
        }
        if (methods) free(methods);
    }

    // === Hook PKSecureElementPass - statut d'activation ===
    Class sePassClass = NSClassFromString(@"PKSecureElementPass");
    if (sePassClass) {
        // deviceAccountNumberSuffix, primaryAccountNumberSuffix existent
        // On s'intéresse aux méthodes de provisioning state
        for (NSString *selName in @[@"isProvisionedOnRemoteDevice",
                                     @"provisioningState",
                                     @"activationState"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([sePassClass instancesRespondToSelector:sel]) {
                wp11log(@"PKSecureElementPass has: %@", selName);
            }
        }
    }

    wp11log(@"PassKit hooks initialized");
}

// ----- Top-level replacements for NPK C functions (for MSHookFunction) -----
static BOOL (*orig_NPKAddToWatch)(id) = NULL;
static BOOL (*orig_NPKSEProv)(id) = NULL;
static BOOL (*orig_NPKGlory)(id) = NULL;
static BOOL (*orig_NPKConnectedFromService)(id) = NULL;
static BOOL (*orig_NPKCurrentlyPairing)(void) = NULL;
static BOOL repl_NPKAddToWatch(id pass) {
    wp11log(@" [passd] NPKIsAddToWatchSupported → YES (forced)");
    return YES;
}
static BOOL repl_NPKSEProv(id dev) {
    wp11log(@" [passd] CanProvisionSecureElementPasses → YES (forced)");
    return YES;
}
static BOOL repl_NPKGlory(id dev) {
    wp11log(@" [passd] IsPairedDeviceGloryOrLater → YES (forced)");
    return YES;
}
// CRITICAL: v7.8 — master quick-check gate. When this returns NO, NanoPassKit UI
// fires GIZMO_UNREACHABLE alert in <1s without any server call.
static BOOL repl_NPKConnectedFromService(id service) {
    wp11log(@" [passd] NPKIsConnectedToPairedOrPairingDeviceFromService → YES (forced)");
    return YES;
}
static BOOL repl_NPKCurrentlyPairing(void) {
    // Say we're NOT currently pairing (so flow doesn't get blocked by "in-progress" state)
    return NO;
}

// =====================================================================
// HOOKS: passd — Apple Pay provisioning bypass (v7.7)
// Strategy discovered via NanoPassKit.tbd + PassKitCore.tbd RE :
//   • Apple EXPOSES native override keys (PKDeveloperSettingsEnabled,
//     PKDeviceInformationOverrideProductType, PKClientHTTPHeaderOSPartOverride,
//     PKClientHTTPHeaderHardwarePlatformOverride, PKBypassCertValidation)
//   • NanoPassKit has Tinker/Demo/Simulated modes → relaxes validation
//   • PKPaymentDeviceRegistrationData._productType is settable iVar
//   • NPKPaymentPreflighter iVars expose all pre-flight flags
// =====================================================================
static void hookPassd(void) {
    wp11log(@" [passd] === Apple Pay bypass v7.9 (truly surgical) starting ===");

    // v7.9: MINIMAL scope - don't break Wallet UI
    //   Learnings from v7.7/v7.8:
    //   - NSUserDefaults global writes → broke Wallet
    //   - NPKBluetoothConnectivityCoordinator, NPKCompanionAgentConnection blanket hooks → broke Wallet
    //   - connectionAvailableActions → 0xFFFFFFFF → NSInvalidArgumentException
    //   - NPKPaymentPreflighter _needs*/_checked* blanket → breaks Wallet library sync
    //
    // v7.9 keeps ONLY:
    //   1. The 5 NPKIs* C function hooks (only fire on Add Card quick-check)
    //   2. One specific XPC responder method:
    //      -[NPDCompanionPassLibrary canAddSecureElementPassWithConfiguration:completion:]
    //      This is the exact XPC server method Bridge calls for Add Card.

    dlopen("/System/Library/PrivateFrameworks/NanoPassKit.framework/NanoPassKit", RTLD_LAZY);

    // ---- Step 1: 5 C function gates ----
    void *npk = dlopen("/System/Library/PrivateFrameworks/NanoPassKit.framework/NanoPassKit", RTLD_LAZY);
    if (npk) {
        void *addrMaster = dlsym(npk, "NPKIsConnectedToPairedOrPairingDeviceFromService");
        void *addrPairing = dlsym(npk, "NPKIsCurrentlyPairing");
        void *addrAddToWatch = dlsym(npk, "NPKIsAddToWatchSupportedForCompanionPaymentPass");
        void *addrSEProv = dlsym(npk, "NPKPairedOrPairingDeviceCanProvisionSecureElementPasses");
        void *addrGloryOrLater = dlsym(npk, "NPKIsPairedDeviceGloryOrLater");
        if (addrMaster) MSHookFunction((void *)addrMaster, (void *)repl_NPKConnectedFromService, (void **)&orig_NPKConnectedFromService);
        if (addrPairing) MSHookFunction((void *)addrPairing, (void *)repl_NPKCurrentlyPairing, (void **)&orig_NPKCurrentlyPairing);
        if (addrAddToWatch) MSHookFunction((void *)addrAddToWatch, (void *)repl_NPKAddToWatch, (void **)&orig_NPKAddToWatch);
        if (addrSEProv) MSHookFunction((void *)addrSEProv, (void *)repl_NPKSEProv, (void **)&orig_NPKSEProv);
        if (addrGloryOrLater) MSHookFunction((void *)addrGloryOrLater, (void *)repl_NPKGlory, (void **)&orig_NPKGlory);
        wp11log(@" [passd] 5 NPK C gates hooked");
    }

    // ---- Step 2: THE XPC server method that Bridge hits during Add Card ----
    Class passLib = NSClassFromString(@"NPDCompanionPassLibrary");
    if (passLib) {
        SEL sel = NSSelectorFromString(@"canAddSecureElementPassWithConfiguration:completion:");
        if ([passLib instancesRespondToSelector:sel]) {
            Method m = class_getInstanceMethod(passLib, sel);
            class_replaceMethod(passLib, sel,
                imp_implementationWithBlock(^void(id self, id cfg, void(^completion)(BOOL, NSError *)){
                    wp11log(@" [NPDCompanionPassLibrary] canAddSecureElementPass → (YES, nil) (forced)");
                    if (completion) completion(YES, nil);
                }),
                method_getTypeEncoding(m));
            wp11log(@" [passd] Hooked -[NPDCompanionPassLibrary canAddSecureElementPassWithConfiguration:completion:]");
        }
    } else {
        wp11log(@" [passd] NPDCompanionPassLibrary NOT found (will be in NPKCompanionAgent)");
    }

    wp11log(@" [passd] === v7.9 surgical bypass installed ===");
}

// v7.8 — posix_spawn hook in SpringBoard to force DYLD_INSERT_LIBRARIES
// into Bridge.app when it spawns. No snprintf/format strings (logos bug).
static int (*orig_posix_spawn)(pid_t *pid, const char *path,
                               const posix_spawn_file_actions_t *file_actions,
                               const posix_spawnattr_t *attrp,
                               char *const argv[],
                               char *const envp[]) = NULL;

// v7.10: Hook in xpcproxy (where app spawns happen).
// Catch Bridge.app path (which nathanlr xpcproxyhook skips since not in allowed prefixes)
// Inject DYLD_INSERT_LIBRARIES=generalhook.dylib so generalhook loads WatchPair11 via TweakInject.
static int repl_posix_spawn(pid_t *pid, const char *path,
                            const posix_spawn_file_actions_t *file_actions,
                            const posix_spawnattr_t *attrp,
                            char *const argv[],
                            char *const envp[]) {
    // Intercept Bridge.app launch from xpcproxy
    BOOL isBridge = path && (strstr(path, "/Bridge.app/Bridge") != NULL);
    BOOL isVarContainers = path && (strstr(path, "/var/containers/Bundle/Application/") != NULL ||
                                     strstr(path, "/private/var/containers/Bundle/Application/") != NULL);

    if (isBridge && isVarContainers) {
        wp11log(@" [xpcproxy] Bridge intercepted, injecting generalhook+WatchPair11");

        // Inject generalhook (which auto-loads TweakLoader + all TweakInject filters)
        // Path is resolved at runtime under roothide because the jbroot prefix is randomized.
        char injectLibBuf[1024];
        snprintf(injectLibBuf, sizeof(injectLibBuf), "%s:%s",
                 WP11_JBROOT("/usr/lib/hooks/generalhook.dylib"),
                 WP11_JBROOT("/Library/MobileSubstrate/DynamicLibraries/WatchPair11.dylib"));
        const char *injectLib = injectLibBuf;

        int nenv = 0;
        if (envp) for (char *const *e = envp; *e; e++) nenv++;

        char **newenv = (char **)calloc(nenv + 2, sizeof(char *));
        int ni = 0;
        BOOL foundDyld = NO;

        // Build "DYLD_INSERT_LIBRARIES=<lib>" manually (no format string)
        size_t dlibLen = strlen(injectLib);
        char *dyldBuf = (char *)malloc(dlibLen + 32);
        strcpy(dyldBuf, "DYLD_INSERT_LIBRARIES=");
        strcat(dyldBuf, injectLib);

        if (envp) {
            for (char *const *e = envp; *e; e++) {
                if (strncmp(*e, "DYLD_INSERT_LIBRARIES=", 22) == 0) {
                    size_t exLen = strlen(*e);
                    char *mixed = (char *)malloc(dlibLen + exLen + 32);
                    strcpy(mixed, "DYLD_INSERT_LIBRARIES=");
                    strcat(mixed, injectLib);
                    strcat(mixed, ":");
                    strcat(mixed, (*e) + 22);
                    newenv[ni++] = mixed;
                    foundDyld = YES;
                } else {
                    newenv[ni++] = *e;
                }
            }
        }
        if (!foundDyld) {
            newenv[ni++] = dyldBuf;
        } else {
            free(dyldBuf);
        }
        newenv[ni] = NULL;

        int result = orig_posix_spawn(pid, path, file_actions, attrp, argv, newenv);
        wp11log(@" [xpcproxy] Bridge spawned pid=%d result=%d", pid ? *pid : -1, result);
        return result;
    }
    return orig_posix_spawn(pid, path, file_actions, attrp, argv, envp);
}

static void hookBridgeSpawn(void) {
    wp11log(@" [xpcproxy] Installing posix_spawn hook");
    MSHookFunction((void *)posix_spawn, (void *)repl_posix_spawn, (void **)&orig_posix_spawn);
}

// =====================================================================
// HOOKS: Message Relay - Envoi de messages depuis la Watch
// Le Watch envoie via IDS → imagent doit relayer (iMessage/SMS)
// imagent refuse car il voit iOS 16 = "device incompatible"
// =====================================================================
static void hookMessageRelay(void) {
    // Charger les frameworks iMessage
    dlopen("/System/Library/PrivateFrameworks/IMFoundation.framework/IMFoundation", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/IMDPersistence.framework/IMDPersistence", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/IMDaemonCore.framework/IMDaemonCore", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/IMTransferServices.framework/IMTransferServices", RTLD_LAZY);

    // === 1. Hook IMService — le service iMessage/SMS vérifie la compatibilité ===
    Class imServiceClass = NSClassFromString(@"IMService");
    if (imServiceClass) {
        // Scanner les méthodes pertinentes
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(imServiceClass, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if ([selName containsString:@"relay"] ||
                [selName containsString:@"Relay"] ||
                [selName containsString:@"canSend"] ||
                [selName containsString:@"companion"] ||
                [selName containsString:@"Companion"] ||
                [selName containsString:@"remote"] ||
                [selName containsString:@"Remote"] ||
                [selName containsString:@"forward"] ||
                [selName containsString:@"Forward"] ||
                [selName containsString:@"compat"] ||
                [selName containsString:@"supported"] ||
                [selName containsString:@"available"] ||
                [selName containsString:@"enabled"]) {
                wp11log(@"IMService method: %@", selName);
            }
        }
        if (methods) free(methods);
    }

    // === 2. Hook IMDService (daemon-side) ===
    Class imdServiceClass = NSClassFromString(@"IMDService");
    if (imdServiceClass) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(imdServiceClass, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if ([selName containsString:@"relay"] ||
                [selName containsString:@"Relay"] ||
                [selName containsString:@"canSend"] ||
                [selName containsString:@"forward"] ||
                [selName containsString:@"compat"] ||
                [selName containsString:@"remote"] ||
                [selName containsString:@"companion"]) {
                wp11log(@"IMDService method: %@", selName);
            }
        }
        if (methods) free(methods);
    }

    // === 3. Hook IMAccount — le compte iMessage/SMS vérifie si le relay est autorisé ===
    Class imAccountClass = NSClassFromString(@"IMAccount");
    if (imAccountClass) {
        // Force les méthodes de relay/capabilities → YES
        for (NSString *selName in @[@"allowsSMSRelay",
                                     @"isSMSRelayCapable",
                                     @"isSMSRelayEnabled",
                                     @"allowsRelaying",
                                     @"isRelayingEnabled",
                                     @"isRelaySMSEnabled",
                                     @"canRelaySMS",
                                     @"supportsRemoteMessages",
                                     @"isActive",
                                     @"isEnabled",
                                     @"isConnected",
                                     @"isOperational"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([imAccountClass instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(imAccountClass, sel);
                if (m) {
                    class_replaceMethod(imAccountClass, sel,
                        imp_implementationWithBlock(^BOOL(id self) {
                            wp11log(@"IMAccount.%@ -> YES (forced)", selName);
                            return YES;
                        }),
                        method_getTypeEncoding(m));
                    wp11log(@"Hooked IMAccount.%@ -> YES", selName);
                }
            }
        }

        // Scanner d'autres méthodes relay
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(imAccountClass, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if ([selName containsString:@"relay"] ||
                [selName containsString:@"Relay"]) {
                wp11log(@"IMAccount relay method: %@", selName);
            }
        }
        if (methods) free(methods);
    }

    // === 4. Hook IMDAccount (daemon-side account) ===
    Class imdAccountClass = NSClassFromString(@"IMDAccount");
    if (imdAccountClass) {
        for (NSString *selName in @[@"allowsSMSRelay",
                                     @"isSMSRelayCapable",
                                     @"isSMSRelayEnabled",
                                     @"allowsRelaying",
                                     @"isRelayingEnabled",
                                     @"canRelaySMS",
                                     @"isActive",
                                     @"isEnabled",
                                     @"isConnected",
                                     @"isOperational"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([imdAccountClass instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(imdAccountClass, sel);
                if (m) {
                    class_replaceMethod(imdAccountClass, sel,
                        imp_implementationWithBlock(^BOOL(id self) {
                            wp11log(@"IMDAccount.%@ -> YES (forced)", selName);
                            return YES;
                        }),
                        method_getTypeEncoding(m));
                    wp11log(@"Hooked IMDAccount.%@ -> YES", selName);
                }
            }
        }
    }

    // === 5. Hook SMSRelay classes ===
    for (NSString *className in @[@"IMSMSRelayController",
                                    @"IMDSMSRelayController",
                                    @"IMRelayController",
                                    @"IMDRelayController",
                                    @"IMRemoteDeviceRelayController"]) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        wp11log(@"Found relay class: %@", className);

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            wp11log(@"  -[%@ %@]", className, selName);

            // Hook BOOL methods qui contiennent "can", "enabled", "supported", "available"
            if ([selName hasPrefix:@"can"] ||
                [selName hasPrefix:@"is"] ||
                [selName hasPrefix:@"should"] ||
                [selName containsString:@"enabled"] ||
                [selName containsString:@"supported"] ||
                [selName containsString:@"available"] ||
                [selName containsString:@"capable"]) {
                Method m = methods[i];
                const char *retType = method_copyReturnType(m);
                if (retType && retType[0] == 'B') {
                    unsigned int argCount = method_getNumberOfArguments(m);
                    if (argCount == 2) { // no args besides self+_cmd
                        class_replaceMethod(cls, method_getName(m),
                            imp_implementationWithBlock(^BOOL(id self) {
                                wp11log(@"%@.%@ -> YES (forced)", className, selName);
                                return YES;
                            }),
                            method_getTypeEncoding(m));
                        wp11log(@"Hooked %@.%@ -> YES", className, selName);
                    } else if (argCount == 3) {
                        class_replaceMethod(cls, method_getName(m),
                            imp_implementationWithBlock(^BOOL(id self, id arg1) {
                                wp11log(@"%@.%@ -> YES (forced)", className, selName);
                                return YES;
                            }),
                            method_getTypeEncoding(m));
                        wp11log(@"Hooked %@.%@: -> YES", className, selName);
                    }
                }
                if (retType) free((void*)retType);
            }
        }
        if (methods) free(methods);
    }

    // === 6. Hook IMDMessageStore / IMMessage send path ===
    // Quand la Watch envoie un message, il passe par IMDMessageStore
    Class msgStoreClass = NSClassFromString(@"IMDMessageStore");
    if (msgStoreClass) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(msgStoreClass, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            if ([selName containsString:@"send"] ||
                [selName containsString:@"Send"] ||
                [selName containsString:@"relay"] ||
                [selName containsString:@"Relay"] ||
                [selName containsString:@"remote"] ||
                [selName containsString:@"companion"]) {
                wp11log(@"IMDMessageStore: %@", selName);
            }
        }
        if (methods) free(methods);
    }

    // === 7. Hook CKSMSRelayAccount si disponible (ChatKit) ===
    Class ckRelayClass = NSClassFromString(@"CKSMSRelayAccount");
    if (ckRelayClass) {
        wp11log(@"Found CKSMSRelayAccount");
        for (NSString *selName in @[@"isRelayEnabled", @"canRelay", @"isEnabled"]) {
            SEL sel = NSSelectorFromString(selName);
            if ([ckRelayClass instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(ckRelayClass, sel);
                if (m) {
                    class_replaceMethod(ckRelayClass, sel,
                        imp_implementationWithBlock(^BOOL(id self) { return YES; }),
                        method_getTypeEncoding(m));
                    wp11log(@"Hooked CKSMSRelayAccount.%@ -> YES", selName);
                }
            }
        }
    }

    // === 8. Hook IMRemoteDevice pour forcer la compatibilité Watch ===
    for (NSString *className in @[@"IMRemoteDevice",
                                    @"IMCompanionDevice",
                                    @"IMNanoDevice",
                                    @"IMDCompanionDevice"]) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        wp11log(@"Found device class: %@", className);

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *selName = NSStringFromSelector(method_getName(methods[i]));
            // Log toutes les méthodes pour diagnostic
            wp11log(@"  -[%@ %@]", className, selName);

            // Force BOOL methods pertinentes → YES
            if ([selName containsString:@"compat"] ||
                [selName containsString:@"support"] ||
                [selName containsString:@"capable"] ||
                [selName containsString:@"available"] ||
                [selName containsString:@"enabled"] ||
                [selName containsString:@"canSend"] ||
                [selName containsString:@"canRelay"]) {
                Method m = methods[i];
                const char *retType = method_copyReturnType(m);
                if (retType && retType[0] == 'B') {
                    unsigned int argCount = method_getNumberOfArguments(m);
                    if (argCount == 2) {
                        class_replaceMethod(cls, method_getName(m),
                            imp_implementationWithBlock(^BOOL(id self) {
                                wp11log(@"%@.%@ -> YES (forced)", className, selName);
                                return YES;
                            }),
                            method_getTypeEncoding(m));
                    }
                }
                if (retType) free((void*)retType);
            }
        }
        if (methods) free(methods);
    }

    wp11log(@"Message relay hooks initialized");
}

// =====================================================================
// HOOKS: APSSupport — Fix envoi Messages depuis la Watch
// Inspiré de WatchFix (577fkj/WatchFix, GPLv3)
// Après chaque incomingPresence de la Watch, force sendProxyIsConnected:YES
// pour que apsd signale correctement la connexion proxy APS.
// Sans ça, les messages sortants depuis la Watch ne partent pas.
// =====================================================================
__attribute__((unused))
static void hookAPSSupport(void) {
    Class proxyClass = NSClassFromString(@"APSProxyClient");
    if (!proxyClass) {
        wp11log(@"[APS] APSProxyClient not found, skipping");
        return;
    }

    SEL presenceSel = NSSelectorFromString(@"incomingPresenceWithCertificate:nonce:signature:token:hwVersion:swVersion:swBuild:");
    Method m = class_getInstanceMethod(proxyClass, presenceSel);
    if (!m) {
        wp11log(@"[APS] incomingPresence method not found");
        return;
    }

    IMP origIMP = method_getImplementation(m);
    class_replaceMethod(proxyClass, presenceSel,
        imp_implementationWithBlock(^(id self, NSData *cert, NSData *nonce, NSData *sig,
                                      NSData *token, NSString *hwVer, NSString *swVer, NSString *swBuild) {
            wp11log(@"[APS] incomingPresence: hw=%@ sw=%@ build=%@", hwVer, swVer, swBuild);

            // Call original
            ((void(*)(id, SEL, NSData*, NSData*, NSData*, NSData*, NSString*, NSString*, NSString*))origIMP)
                (self, presenceSel, cert, nonce, sig, token, hwVer, swVer, swBuild);

            // Check if proxy client is active and connected
            BOOL isActive = NO;
            SEL activeSel = NSSelectorFromString(@"isActive");
            if ([self respondsToSelector:activeSel]) {
                isActive = ((BOOL(*)(id, SEL))objc_msgSend)(self, activeSel);
            }
            if (!isActive) {
                wp11log(@"[APS] client not active, skip");
                return;
            }

            // Check connected on interface 0 or 1
            SEL connSel = NSSelectorFromString(@"isConnectedOnInterface:");
            SEL disconnSel = NSSelectorFromString(@"needsToDisconnectOnInterface:");
            BOOL connected = NO;
            if ([self respondsToSelector:connSel] && [self respondsToSelector:disconnSel]) {
                for (int iface = 0; iface <= 1; iface++) {
                    BOOL conn = ((BOOL(*)(id, SEL, int))objc_msgSend)(self, connSel, iface);
                    BOOL disc = ((BOOL(*)(id, SEL, int))objc_msgSend)(self, disconnSel, iface);
                    if (conn && !disc) {
                        connected = YES;
                        break;
                    }
                }
            }
            if (!connected) {
                wp11log(@"[APS] not connected on any interface, skip");
                return;
            }

            // Read _guid ivar
            NSString *guid = nil;
            Ivar guidIvar = class_getInstanceVariable([self class], "_guid");
            if (guidIvar) {
                guid = object_getIvar(self, guidIvar);
            }

            // Read _environment ivar -> name
            NSString *envName = nil;
            Ivar envIvar = class_getInstanceVariable([self class], "_environment");
            if (envIvar) {
                id env = object_getIvar(self, envIvar);
                SEL nameSel = NSSelectorFromString(@"name");
                if (env && [env respondsToSelector:nameSel]) {
                    envName = ((NSString*(*)(id, SEL))objc_msgSend)(env, nameSel);
                }
            }

            // Get proxyManager and send connected state
            SEL pmSel = NSSelectorFromString(@"proxyManager");
            if (!guid || !envName || ![self respondsToSelector:pmSel]) {
                wp11log(@"[APS] missing state: guid=%@ env=%@", guid, envName);
                return;
            }

            id proxyManager = ((id(*)(id, SEL))objc_msgSend)(self, pmSel);
            SEL sendSel = NSSelectorFromString(@"sendProxyIsConnected:guid:environmentName:");
            if (proxyManager && [proxyManager respondsToSelector:sendSel]) {
                ((void(*)(id, SEL, BOOL, NSString*, NSString*))objc_msgSend)
                    (proxyManager, sendSel, YES, guid, envName);
                wp11log(@"[APS] sendProxyIsConnected:YES guid=%@ env=%@", guid, envName);
            }
        }),
        method_getTypeEncoding(m));

    wp11log(@"[APS] APSSupport hooks initialized (Messages fix)");
}

// =====================================================================
// HOOKS: AppsSupport — Fix apps Watch absentes / auto-desinstallées
// Inspiré de WatchFix (577fkj/WatchFix, GPLv3)
// 1. Ajoute MobileSMS au mapping apps systeme (empêche la desinstallation auto)
// 2. Spoof la version watchOS pour la validation des bundles embedded Watch
// =====================================================================
static void hookAppsSupport(void) {
    // --- Hook 1: ACXAvailableApplicationManager (dans appconduitd) ---
    // Ajoute MobileSMS au mapping supplemental pour watchOS 6+
    Class appManagerClass = NSClassFromString(@"ACXAvailableApplicationManager");
    if (appManagerClass) {
        SEL mappingSel = NSSelectorFromString(@"_supplementalSystemAppBundleIDMappingForWatchOSSixAndLater");
        Method m = class_getInstanceMethod(appManagerClass, mappingSel);
        if (m) {
            IMP origIMP = method_getImplementation(m);
            class_replaceMethod(appManagerClass, mappingSel,
                imp_implementationWithBlock(^NSDictionary *(id self) {
                    NSDictionary *orig = ((NSDictionary*(*)(id, SEL))origIMP)(self, mappingSel);
                    NSMutableDictionary *mapping = [orig mutableCopy] ?: [NSMutableDictionary dictionary];
                    [mapping setObject:@"com.apple.MobileSMS" forKey:@"com.apple.MobileSMS"];
                    wp11log(@"[Apps] Added MobileSMS to supplemental mapping (%lu entries)", (unsigned long)mapping.count);
                    return mapping;
                }),
                method_getTypeEncoding(m));
            wp11log(@"[Apps] ACXAvailableApplicationManager hook installed");
        }

        // --- Hook 1b (v7.5): _bundleIDsOfInstallableSystemAppsForLocallyAvailableApps ---
        // Force Messages + Wallet dans la liste installable pour la Watch
        // Check both ACXAvailableApplicationManager ET ACXAvailableSystemAppList
        SEL installableSel = NSSelectorFromString(@"_bundleIDsOfInstallableSystemAppsForLocallyAvailableApps");
        Class listClass = NSClassFromString(@"ACXAvailableSystemAppList");

        for (Class cls in @[appManagerClass, listClass ?: (id)[NSNull null]]) {
            if (!cls || cls == (id)[NSNull null]) continue;
            Method im = class_getInstanceMethod(cls, installableSel);
            if (im) {
                IMP origIMPi = method_getImplementation(im);
                class_replaceMethod(cls, installableSel,
                    imp_implementationWithBlock(^NSArray *(id self) {
                        NSArray *orig = ((NSArray*(*)(id, SEL))origIMPi)(self, installableSel);
                        NSMutableSet *set = [NSMutableSet setWithArray:orig ?: @[]];
                        [set addObject:@"com.apple.MobileSMS"];
                        [set addObject:@"com.apple.Passbook"];
                        [set addObject:@"com.apple.NanoPassbook"];
                        NSArray *result = [set allObjects];
                        wp11log(@"[Apps] _bundleIDsOfInstallable(%@) force-added MobileSMS + Passbook (%lu entries)", NSStringFromClass(cls), (unsigned long)result.count);
                        return result;
                    }),
                    method_getTypeEncoding(im));
                wp11log(@"[Apps] _bundleIDsOfInstallable hook installed on %@", NSStringFromClass(cls));
            } else {
                wp11log(@"[Apps] _bundleIDsOfInstallable NOT found on %@", NSStringFromClass(cls));
            }
        }

        // --- Hook 1c (v7.5): _bundleIDsOfInstallableSystemAppsIgnoringCounterpartAvailability ---
        SEL ignoreSel = NSSelectorFromString(@"_bundleIDsOfInstallableSystemAppsIgnoringCounterpartAvailability");
        Method igm = class_getInstanceMethod(appManagerClass, ignoreSel);
        if (igm) {
            IMP origIMPig = method_getImplementation(igm);
            class_replaceMethod(appManagerClass, ignoreSel,
                imp_implementationWithBlock(^NSArray *(id self) {
                    NSArray *orig = ((NSArray*(*)(id, SEL))origIMPig)(self, ignoreSel);
                    NSMutableSet *set = [NSMutableSet setWithArray:orig ?: @[]];
                    [set addObject:@"com.apple.MobileSMS"];
                    [set addObject:@"com.apple.Passbook"];
                    [set addObject:@"com.apple.NanoPassbook"];
                    return [set allObjects];
                }),
                method_getTypeEncoding(igm));
        }

        // --- Hook 1d (v7.5): _appIsInstallable ---
        // Force TOUT app à être installable côté Watch
        SEL installSel = NSSelectorFromString(@"_appIsInstallable:");
        Method iim = class_getInstanceMethod(appManagerClass, installSel);
        if (iim) {
            class_replaceMethod(appManagerClass, installSel,
                imp_implementationWithBlock(^BOOL(id self, id app) {
                    return YES;
                }),
                method_getTypeEncoding(iim));
            wp11log(@"[Apps] _appIsInstallable hook installed (always YES)");
        }
    }

    // --- Hook 2: MIEmbeddedWatchBundle (dans installd) ---
    // Spoof la version watchOS pour que tous les bundles passent la validation
    Class watchBundleClass = NSClassFromString(@"MIEmbeddedWatchBundle");
    if (watchBundleClass) {
        // isApplicableToKnownWatchOSVersion → force via isApplicableToOSVersion:error:
        SEL applicableSel = NSSelectorFromString(@"isApplicableToKnownWatchOSVersion");
        Method am = class_getInstanceMethod(watchBundleClass, applicableSel);
        if (am) {
            class_replaceMethod(watchBundleClass, applicableSel,
                imp_implementationWithBlock(^BOOL(id self) {
                    SEL spoofSel = NSSelectorFromString(@"isApplicableToOSVersion:error:");
                    if ([self respondsToSelector:spoofSel]) {
                        return ((BOOL(*)(id, SEL, NSString*, id*))objc_msgSend)(self, spoofSel, @"11.9999", nil);
                    }
                    return YES;
                }),
                method_getTypeEncoding(am));
        }

        // currentOSVersionForValidationWithError: → return "11.9999"
        SEL versionSel = NSSelectorFromString(@"currentOSVersionForValidationWithError:");
        Method vm = class_getInstanceMethod(watchBundleClass, versionSel);
        if (vm) {
            class_replaceMethod(watchBundleClass, versionSel,
                imp_implementationWithBlock(^NSString *(id self, id *error) {
                    return @"11.9999";
                }),
                method_getTypeEncoding(vm));
        }

        wp11log(@"[Apps] MIEmbeddedWatchBundle hooks installed (version spoof 11.9999)");
    }
}

// =====================================================================
// HOOKS: IDS UTun — Fix compatibilité couche IDS tunnel
// Inspiré de WatchFix (577fkj/WatchFix, GPLv3)
// Hook IDSUTunControlMessage_Hello pour forcer la version de compatibilité
// du service IDS, empêchant le rejet des messages Watch.
// =====================================================================
static void hookIDSUTun(void) {
    Class helloClass = NSClassFromString(@"IDSUTunControlMessage_Hello");
    if (!helloClass) {
        wp11log(@"[UTun] IDSUTunControlMessage_Hello not found, skipping");
        return;
    }

    SEL setMinSel = NSSelectorFromString(@"setServiceMinCompatibilityVersion:");
    Method m = class_getInstanceMethod(helloClass, setMinSel);
    if (!m) {
        wp11log(@"[UTun] setServiceMinCompatibilityVersion: not found");
        return;
    }

    class_replaceMethod(helloClass, setMinSel,
        imp_implementationWithBlock(^(id self, NSNumber *version) {
            NSInteger v = [version integerValue];
            wp11log(@"[UTun] setServiceMinCompatibilityVersion: %ld", (long)v);
            // Si la version min est trop basse (< 18), on la monte pour que
            // le handshake IDS accepte notre device comme compatible
            if (v < 18) {
                v = MAX_COMPAT;
                wp11log(@"[UTun] -> forced to %ld", (long)v);
            }
            NSNumber *newVersion = [NSNumber numberWithInteger:v];
            // Set via ivar directly (comme WatchFix)
            Ivar ivar = class_getInstanceVariable([self class], "_serviceMinCompatibilityVersion");
            if (ivar) {
                object_setIvar(self, ivar, newVersion);
            }
        }),
        method_getTypeEncoding(m));

    wp11log(@"[UTun] IDSUTunControlMessage_Hello hook installed");
}

// =====================================================================
// LOGGER: Liste toutes les méthodes unpair-related (sans les bloquer)
// =====================================================================
static void logUnpairMethods(void) {
    Class regClass = NSClassFromString(@"NRPairedDeviceRegistry");
    if (!regClass) return;

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(regClass, &methodCount);
    wp11log(@"NRPairedDeviceRegistry a %u méthodes", methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        NSString *selName = NSStringFromSelector(method_getName(methods[i]));
        if ([selName containsString:@"npair"] ||
            [selName containsString:@"etrigger"] ||
            [selName containsString:@"bliter"]) {
            wp11log(@"  Méthode trouvée: %@", selName);
        }
    }
    free(methods);
}

// =====================================================================
// LOGGER v6.1: Diagnostic dump pour BLE proximity classes
// Liste les méthodes des classes impliquées dans le pairing/proximity
// pour identifier les hook targets pour le fix drain batterie
// =====================================================================
static void dumpClassMethods(NSString *className, NSArray<NSString *> *patterns) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        wp11log(@"  [DUMP] %@ NOT loaded", className);
        return;
    }

    unsigned int instCount = 0, classCount = 0;
    Method *instMethods = class_copyMethodList(cls, &instCount);
    Method *classMethods = class_copyMethodList(object_getClass(cls), &classCount);
    wp11log(@"  [DUMP] === %@ (%u inst + %u class) ===", className, instCount, classCount);

    int matched = 0;
    for (unsigned int i = 0; i < instCount; i++) {
        NSString *sel = NSStringFromSelector(method_getName(instMethods[i]));
        BOOL show = (patterns.count == 0);
        for (NSString *p in patterns) {
            if ([sel rangeOfString:p options:NSCaseInsensitiveSearch].location != NSNotFound) { show = YES; break; }
        }
        if (show) { wp11log(@"  [DUMP]   -%@", sel); matched++; }
    }
    for (unsigned int i = 0; i < classCount; i++) {
        NSString *sel = NSStringFromSelector(method_getName(classMethods[i]));
        BOOL show = (patterns.count == 0);
        for (NSString *p in patterns) {
            if ([sel rangeOfString:p options:NSCaseInsensitiveSearch].location != NSNotFound) { show = YES; break; }
        }
        if (show) { wp11log(@"  [DUMP]   +%@", sel); matched++; }
    }
    wp11log(@"  [DUMP]   (%d matched)", matched);
    if (instMethods) free(instMethods);
    if (classMethods) free(classMethods);
}

// =====================================================================
// HOOKS v6.2-v6.3: Logging + discrimination + transformation BLE parsers
// =====================================================================
static IMP s_orig_setBleAdvertisementData = NULL;
static IMP s_orig_parseNearbyActionV2 = NULL;
static IMP s_orig_parseNearbyAction = NULL;
static IMP s_orig_setNearbyActionV2Type = NULL;
static IMP s_orig_setNearbyActionType = NULL;
static IMP s_orig_setNearbyActionAuthTag = NULL;
static IMP s_orig_setNearbyActionV2Flags = NULL;
static IMP s_orig_setNearbyActionV2TargetData = NULL;
static IMP s_orig_setLeAdvName = NULL;
static IMP s_orig_setNearbyActionDeviceClass = NULL;

// Throttle: limit log spam, only log first N occurrences per second
static int s_logCounter = 0;
static NSTimeInterval s_lastLogReset = 0;
#define MAX_LOG_PER_SEC 30
static BOOL shouldLog(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - s_lastLogReset >= 1.0) {
        s_lastLogReset = now;
        s_logCounter = 0;
    }
    if (s_logCounter < MAX_LOG_PER_SEC) { s_logCounter++; return YES; }
    return NO;
}

// Try to extract a useful device identifier from a CBDevice instance
static NSString *deviceTag(id self) {
    @try {
        SEL selAddr = @selector(deviceAddress);
        SEL selName = @selector(leAdvName);
        SEL selClass = @selector(nearbyActionDeviceClass);
        NSString *addr = nil, *name = nil;
        if ([self respondsToSelector:selAddr]) {
            id a = ((id(*)(id, SEL))objc_msgSend)(self, selAddr);
            if (a) addr = [a description];
        }
        if ([self respondsToSelector:selName]) {
            id n = ((id(*)(id, SEL))objc_msgSend)(self, selName);
            if (n) name = [n description];
        }
        uint8_t devClass = 0;
        if ([self respondsToSelector:selClass]) {
            devClass = ((uint8_t(*)(id, SEL))objc_msgSend)(self, selClass);
        }
        return [NSString stringWithFormat:@"<%@ name=%@ devClass=0x%02x>",
                addr ?: @"?", name ?: @"?", devClass];
    } @catch (NSException *e) {
        return @"<err>";
    }
}

// Helper: format NSData as hex for logging
static NSString *hexDump(NSData *d, NSUInteger maxBytes) {
    if (!d || d.length == 0) return @"<empty>";
    NSUInteger n = MIN(d.length, maxBytes);
    NSMutableString *s = [NSMutableString stringWithCapacity:n*3];
    const uint8_t *b = (const uint8_t *)d.bytes;
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    if (d.length > maxBytes) [s appendFormat:@"..(%lu)", (unsigned long)d.length];
    return s;
}

// Hook: -[CBDevice setBleAdvertisementData:] — entry point for raw adv bytes
static void hooked_setBleAdvertisementData(id self, SEL _cmd, NSData *data) {
    @try {
        wp11log(@"[BLE] setBleAdvertisementData: len=%lu hex=%@",
                (unsigned long)(data ? data.length : 0), hexDump(data, 80));
    } @catch (NSException *e) {}
    if (s_orig_setBleAdvertisementData) {
        ((void(*)(id, SEL, NSData *))s_orig_setBleAdvertisementData)(self, _cmd, data);
    }
}

// Hook: -[CBDevice _parseNearbyActionV2Ptr:end:] — V2 parser entry
// Signature: takes raw byte pointers, no NSData
static void hooked_parseNearbyActionV2(id self, SEL _cmd, const uint8_t *ptr, const uint8_t *end) {
    if (ptr && end && end > ptr) {
        NSUInteger len = MIN((NSUInteger)(end - ptr), (NSUInteger)64);
        NSData *d = [NSData dataWithBytes:ptr length:len];
        wp11log(@"[BLE] _parseNearbyActionV2 len=%ld hex=%@", (long)(end - ptr), hexDump(d, 64));
    }
    if (s_orig_parseNearbyActionV2) {
        ((void(*)(id, SEL, const uint8_t *, const uint8_t *))s_orig_parseNearbyActionV2)(self, _cmd, ptr, end);
    }
}

// Hook: -[CBDevice _parseNearbyActionPtr:end:] — V1 parser entry
static void hooked_parseNearbyAction(id self, SEL _cmd, const uint8_t *ptr, const uint8_t *end) {
    if (ptr && end && end > ptr) {
        NSUInteger len = MIN((NSUInteger)(end - ptr), (NSUInteger)64);
        NSData *d = [NSData dataWithBytes:ptr length:len];
        wp11log(@"[BLE] _parseNearbyAction(V1) len=%ld hex=%@", (long)(end - ptr), hexDump(d, 64));
    }
    if (s_orig_parseNearbyAction) {
        ((void(*)(id, SEL, const uint8_t *, const uint8_t *))s_orig_parseNearbyAction)(self, _cmd, ptr, end);
    }
}

// v6.4: revenir à logging pur, snapshot complet du CBDevice quand un setter trigger
static NSString *snapshotDevice(id self) {
    @try {
        #define READ_U8(name) ({ \
            SEL _s = @selector(name); \
            uint8_t _v = 0; \
            if ([self respondsToSelector:_s]) _v = ((uint8_t(*)(id, SEL))objc_msgSend)(self, _s); \
            _v; })
        #define READ_OBJ(name) ({ \
            SEL _s = @selector(name); \
            id _v = nil; \
            if ([self respondsToSelector:_s]) _v = ((id(*)(id, SEL))objc_msgSend)(self, _s); \
            _v; })

        uint8_t nat = READ_U8(nearbyActionType);
        uint8_t nav2t = READ_U8(nearbyActionV2Type);
        uint8_t nav2f = READ_U8(nearbyActionV2Flags);
        uint8_t nadc = READ_U8(nearbyActionDeviceClass);
        uint8_t naf = READ_U8(nearbyActionFlags);
        uint8_t nif = READ_U8(nearbyInfoFlags);
        NSData *advData = READ_OBJ(bleAdvertisementData);
        NSString *advName = READ_OBJ(leAdvName);
        NSData *authTag = READ_OBJ(nearbyActionAuthTag);
        NSData *naV2tgt = READ_OBJ(nearbyActionV2TargetData);

        return [NSString stringWithFormat:@"naT=0x%02x naV2T=0x%02x naV2F=0x%02x dc=0x%02x naF=0x%02x niF=0x%02x adv=%@ name=%@ auth=%@ tgt=%@",
                nat, nav2t, nav2f, nadc, naf, nif,
                hexDump(advData, 32), advName ?: @"-",
                hexDump(authTag, 8), hexDump(naV2tgt, 16)];
        #undef READ_U8
        #undef READ_OBJ
    } @catch (NSException *e) {
        return @"<snap-err>";
    }
}

static int s_btTraceCount = 0;
static void hooked_setNearbyActionV2Type(id self, SEL _cmd, uint8_t type) {
    if (shouldLog()) {
        wp11log(@"[BLE] setNearbyActionV2Type: 0x%02x SNAP[%@]", type, snapshotDevice(self));
    }
    // v6.8: dump backtrace the first 3 times to identify the CALLER
    if (s_btTraceCount < 3) {
        s_btTraceCount++;
        NSArray *bt = [NSThread callStackSymbols];
        wp11log(@"[BLE] === BACKTRACE setNearbyActionV2Type (call #%d) ===", s_btTraceCount);
        for (NSUInteger i = 0; i < MIN(bt.count, (NSUInteger)15); i++) {
            wp11log(@"[BLE]   %@", bt[i]);
        }
    }
    // v6.8: si type == 0x00 (parsing raté du watchOS 11.5 adv 0x14),
    // ne PAS propager au CBDevice — laisse la valeur précédente en place
    // plutôt que d'écraser avec 0x00 "unknown"
    if (type == 0x00) {
        if (s_btTraceCount <= 3) {
            wp11log(@"[BLE] BLOCKED setNearbyActionV2Type:0x00 (would set unknown)");
        }
        return;  // skip the original setter — don't overwrite with 0x00
    }
    if (s_orig_setNearbyActionV2Type) {
        ((void(*)(id, SEL, uint8_t))s_orig_setNearbyActionV2Type)(self, _cmd, type);
    }
}

static void hooked_setNearbyActionType(id self, SEL _cmd, uint8_t type) {
    if (shouldLog()) wp11log(@"[BLE] setNearbyActionType: 0x%02x %@", type, deviceTag(self));
    if (s_orig_setNearbyActionType) {
        ((void(*)(id, SEL, uint8_t))s_orig_setNearbyActionType)(self, _cmd, type);
    }
}

static void hooked_setNearbyActionAuthTag(id self, SEL _cmd, NSData *data) {
    if (shouldLog()) wp11log(@"[BLE] setNearbyActionAuthTag: %@ %@", hexDump(data, 16), deviceTag(self));
    if (s_orig_setNearbyActionAuthTag) {
        ((void(*)(id, SEL, NSData *))s_orig_setNearbyActionAuthTag)(self, _cmd, data);
    }
}

static void hooked_setNearbyActionV2Flags(id self, SEL _cmd, uint8_t flags) {
    if (shouldLog()) wp11log(@"[BLE] setNearbyActionV2Flags: 0x%02x %@", flags, deviceTag(self));
    if (s_orig_setNearbyActionV2Flags) {
        ((void(*)(id, SEL, uint8_t))s_orig_setNearbyActionV2Flags)(self, _cmd, flags);
    }
}

static void hooked_setNearbyActionV2TargetData(id self, SEL _cmd, NSData *data) {
    if (shouldLog()) wp11log(@"[BLE] setNearbyActionV2TargetData: %@", hexDump(data, 32));
    if (s_orig_setNearbyActionV2TargetData) {
        ((void(*)(id, SEL, NSData *))s_orig_setNearbyActionV2TargetData)(self, _cmd, data);
    }
}

static void hooked_setLeAdvName(id self, SEL _cmd, NSString *name) {
    if (shouldLog() && name) wp11log(@"[BLE] setLeAdvName: '%@'", name);
    if (s_orig_setLeAdvName) {
        ((void(*)(id, SEL, NSString *))s_orig_setLeAdvName)(self, _cmd, name);
    }
}

static void hooked_setNearbyActionDeviceClass(id self, SEL _cmd, uint8_t cls) {
    if (shouldLog()) wp11log(@"[BLE] setNearbyActionDeviceClass: 0x%02x %@", cls, deviceTag(self));
    if (s_orig_setNearbyActionDeviceClass) {
        ((void(*)(id, SEL, uint8_t))s_orig_setNearbyActionDeviceClass)(self, _cmd, cls);
    }
}

// =====================================================================
// v6.5 — résolution + hook des fonctions C parser BLE adv via MSFindSymbol
// =====================================================================
static void probeCSymbols(void) {
    wp11log(@"==== C symbol probe v6.5 ====");

    // Try to load CoreBluetooth.framework
    void *cbHandle = dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", RTLD_LAZY);
    wp11log(@"[SYM] dlopen CoreBluetooth = %p", cbHandle);
    void *btHandle = dlopen("/usr/sbin/bluetoothd", RTLD_LAZY);
    wp11log(@"[SYM] dlopen bluetoothd = %p", btHandle);

    // Symbols to try
    const char *names[] = {
        "_parseNearbyActionPtr",
        "parseNearbyActionPtr",
        "_parseNearbyActionV2Ptr",
        "parseNearbyActionV2Ptr",
        "_parseNearbyInfoPtr",
        "_parseNearbyInfoV2Ptr",
        "_parseProximityPairingPtr",
        "_parseProximityPairingWxSetupPtr",
        "_parseProximityPairingWxStatusPtr",
        "_nearbyParseNearbyActionPtr",
        "_parseAppleNearbyActionPtr",
        "_parseAppleProximityPairingPtr",
        NULL
    };

    // Probe via dlsym (RTLD_DEFAULT) and dladdr to identify origin
    for (int i = 0; names[i]; i++) {
        void *p = dlsym(RTLD_DEFAULT, names[i]);
        if (!p && names[i][0] == '_') p = dlsym(RTLD_DEFAULT, names[i] + 1);
        if (p) {
            Dl_info info;
            int rc = dladdr(p, &info);
            wp11log(@"[SYM] %-40s = %p (%s)", names[i], p,
                    rc ? (info.dli_fname ?: "?") : "<dladdr fail>");
        } else {
            // Try MSFindSymbol with explicit image
            MSImageRef img = MSGetImageByName("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth");
            if (img) {
                void *q = MSFindSymbol(img, names[i]);
                if (q) {
                    wp11log(@"[SYM] %-40s = %p (CoreBluetooth via MSFindSymbol)", names[i], q);
                    continue;
                }
            }
            img = MSGetImageByName("/usr/sbin/bluetoothd");
            if (img) {
                void *q = MSFindSymbol(img, names[i]);
                if (q) {
                    wp11log(@"[SYM] %-40s = %p (bluetoothd via MSFindSymbol)", names[i], q);
                    continue;
                }
            }
            wp11log(@"[SYM] %-40s = NOT FOUND", names[i]);
        }
    }
    wp11log(@"==== C symbol probe end ====");
}

// v6.4: enumerate all subclasses of CBDevice
static void enumerateCBDeviceSubclasses(void) {
    Class root = NSClassFromString(@"CBDevice");
    if (!root) return;
    int n = objc_getClassList(NULL, 0);
    if (n <= 0 || n > 50000) return;
    Class *list = (Class *)malloc(sizeof(Class) * n);
    objc_getClassList(list, n);
    int found = 0;
    for (int i = 0; i < n; i++) {
        Class c = list[i];
        Class super = class_getSuperclass(c);
        while (super) {
            if (super == root) {
                wp11log(@"[BLE] Subclass of CBDevice: %s", class_getName(c));
                found++;
                break;
            }
            super = class_getSuperclass(super);
        }
    }
    wp11log(@"[BLE] (%d subclasses of CBDevice)", found);
    free(list);
}

static void hookCBDeviceParsers(void) {
    Class cls = NSClassFromString(@"CBDevice");
    if (!cls) {
        wp11log(@"[BLE] CBDevice NOT loaded — cannot hook parsers");
        return;
    }
    enumerateCBDeviceSubclasses();
    probeCSymbols();
    wp11log(@"[BLE] Installing CBDevice parser hooks");

    // setBleAdvertisementData:
    {
        SEL sel = @selector(setBleAdvertisementData:);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            s_orig_setBleAdvertisementData = method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_setBleAdvertisementData);
            wp11log(@"[BLE]   hooked setBleAdvertisementData:");
        }
    }
    // _parseNearbyActionV2Ptr:end:
    {
        SEL sel = NSSelectorFromString(@"_parseNearbyActionV2Ptr:end:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            s_orig_parseNearbyActionV2 = method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_parseNearbyActionV2);
            wp11log(@"[BLE]   hooked _parseNearbyActionV2Ptr:end:");
        }
    }
    // _parseNearbyActionPtr:end:
    {
        SEL sel = NSSelectorFromString(@"_parseNearbyActionPtr:end:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            s_orig_parseNearbyAction = method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_parseNearbyAction);
            wp11log(@"[BLE]   hooked _parseNearbyActionPtr:end:");
        }
    }
    // setNearbyActionV2Type:
    {
        SEL sel = @selector(setNearbyActionV2Type:);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            s_orig_setNearbyActionV2Type = method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_setNearbyActionV2Type);
            wp11log(@"[BLE]   hooked setNearbyActionV2Type:");
        }
    }
    // setNearbyActionType:
    {
        SEL sel = @selector(setNearbyActionType:);
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            s_orig_setNearbyActionType = method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_setNearbyActionType);
            wp11log(@"[BLE]   hooked setNearbyActionType:");
        }
    }
    // v6.3 — additional setter hooks for context
    #define HOOK_SEL(SELNAME, FN, ORIG) do { \
        SEL sel = @selector(SELNAME); \
        Method m = class_getInstanceMethod(cls, sel); \
        if (m) { ORIG = method_getImplementation(m); \
            method_setImplementation(m, (IMP)FN); \
            wp11log(@"[BLE]   hooked " #SELNAME); } \
    } while(0)
    HOOK_SEL(setNearbyActionAuthTag:, hooked_setNearbyActionAuthTag, s_orig_setNearbyActionAuthTag);
    HOOK_SEL(setNearbyActionV2Flags:, hooked_setNearbyActionV2Flags, s_orig_setNearbyActionV2Flags);
    HOOK_SEL(setNearbyActionV2TargetData:, hooked_setNearbyActionV2TargetData, s_orig_setNearbyActionV2TargetData);
    HOOK_SEL(setLeAdvName:, hooked_setLeAdvName, s_orig_setLeAdvName);
    HOOK_SEL(setNearbyActionDeviceClass:, hooked_setNearbyActionDeviceClass, s_orig_setNearbyActionDeviceClass);
    #undef HOOK_SEL
}

// =====================================================================
// HOOKS: NRDeviceMonitor / EPDevice — drain batterie fix (v6.6)
// =====================================================================
// ROOT CAUSE: iOS 16 ne sait pas parser l'adv BLE Nearby Action 0x14 émis
// par watchOS 11.5. setNearbyActionV2Type reçoit 0x00 → iOS pense que le
// device est asleep/far → nanoregistryd flappe deviceIsAsleepDidChange
// toutes les ~5s → le drain batterie bondit.
//
// FIX: forcer isAsleep=NO, isNearby=YES, isProximateExpired=NO dans
// nanoregistryd (là où la décision est prise) pour casser le flapping.
// =====================================================================
__attribute__((unused)) static void hookProximityStateSpoofing(void) {
    // v6.7 : kill-switch runtime. Si /var/tmp/wp11_disable_prox existe, on skip.
    // Les hooks isAsleep=NO / isNearby=YES causent la Watch à marquer l'iPhone comme déconnecté.
    // On doit trouver une meilleure approche (peut-être au niveau bluetoothd parser).
    if (access("/var/tmp/wp11_disable_prox", F_OK) == 0) {
        wp11log(@" [PROX] KILL-SWITCH ACTIVE (/var/tmp/wp11_disable_prox exists) - skipping hooks");
        return;
    }

    dlopen("/System/Library/PrivateFrameworks/NanoRegistry.framework/NanoRegistry", RTLD_LAZY);
    dlopen("/System/Library/PrivateFrameworks/EmbeddedPairing.framework/EmbeddedPairing", RTLD_LAZY);

    // Helper: hook une méthode -(BOOL)selName d'une classe pour qu'elle retourne une valeur fixe
    // Retourne 1 si hooké, 0 sinon.
    int (^hookBoolMethod)(Class, NSString *, BOOL) = ^int(Class cls, NSString *selName, BOOL retVal) {
        if (!cls) return 0;
        SEL sel = NSSelectorFromString(selName);
        if (![cls instancesRespondToSelector:sel]) return 0;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return 0;
        class_replaceMethod(cls, sel,
            imp_implementationWithBlock(^BOOL(id self) { return retVal; }),
            method_getTypeEncoding(m));
        wp11log(@" [PROX] Hooked %@.%@ -> %@",
                NSStringFromClass(cls), selName, retVal ? @"YES" : @"NO");
        return 1;
    };

    int hooked = 0;

    // 1. NRDeviceMonitor — émetteur du state asleep/awake/Bluetooth(None)
    Class nrMonCls = NSClassFromString(@"NRDeviceMonitor");
    if (nrMonCls) {
        hooked += hookBoolMethod(nrMonCls, @"isAsleep", NO);
        hooked += hookBoolMethod(nrMonCls, @"isNearby", YES);
        hooked += hookBoolMethod(nrMonCls, @"isProximate", YES);
        hooked += hookBoolMethod(nrMonCls, @"isAwake", YES);
        // v6.8: hooks critiques pour le companion link "connected" state
        hooked += hookBoolMethod(nrMonCls, @"isConnected", YES);
        hooked += hookBoolMethod(nrMonCls, @"isClassCConnected", YES);
        hooked += hookBoolMethod(nrMonCls, @"isCloudConnected", YES);
        hooked += hookBoolMethod(nrMonCls, @"isEnabled", YES);
        hooked += hookBoolMethod(nrMonCls, @"isRegistered", YES);
    } else {
        wp11log(@" [PROX] NRDeviceMonitor class NOT found");
    }

    // 2. EPDevice — propriétés de proximité
    Class epDevCls = NSClassFromString(@"EPDevice");
    if (epDevCls) {
        hooked += hookBoolMethod(epDevCls, @"isProximateExpired", NO);
        hooked += hookBoolMethod(epDevCls, @"isProximate", YES);
        hooked += hookBoolMethod(epDevCls, @"isDisplayExpired", NO);
    } else {
        wp11log(@" [PROX] EPDevice class NOT found");
    }

    // 3. NRDevice / NRMutableDevice — propriétés de proximité côté NR
    for (NSString *clsName in @[@"NRDevice", @"NRMutableDevice", @"NRPairedDevice"]) {
        Class cls = NSClassFromString(clsName);
        if (cls) {
            hooked += hookBoolMethod(cls, @"isProximate", YES);
            hooked += hookBoolMethod(cls, @"isNearby", YES);
            hooked += hookBoolMethod(cls, @"isAsleep", NO);
            hooked += hookBoolMethod(cls, @"isAwake", YES);
            hooked += hookBoolMethod(cls, @"isConnected", YES);
        }
    }

    wp11log(@" [PROX] Total proximity hooks installed: %d", hooked);
}

static void dumpProximityClasses(void) {
    wp11log(@"==== PROXIMITY CLASS DUMP START ====");

    // Force load NanoRegistry framework if not loaded
    dlopen("/System/Library/PrivateFrameworks/NanoRegistry.framework/NanoRegistry", RTLD_LAZY);

    // 1. The key class — proximity timeout check
    dumpClassMethods(@"EPDevice", @[@"prox", @"display", @"expir", @"state"]);
    // EPCheckBluetoothForIRK
    dumpClassMethods(@"EPCheckBluetoothForIRK", @[]);

    // 2. NRDeviceMonitor — emits the asleep/awake/Bluetooth(None) state
    dumpClassMethods(@"NRDeviceMonitor", @[]);

    // 3. NRDevice — has properties like proximate
    dumpClassMethods(@"NRDevice", @[@"prox", @"sleep", @"awake", @"nearby", @"state", @"update", @"bluetooth"]);
    dumpClassMethods(@"NRMutableDevice", @[@"prox", @"sleep", @"nearby", @"state", @"bluetooth"]);

    // 4. CoreBluetooth daemon-side classes (RX scanner)
    dumpClassMethods(@"CBAdvertiserDaemon", @[@"earby", @"ction", @"date", @"proxim", @"adv", @"discover"]);
    dumpClassMethods(@"CBScannerDaemon", @[@"earby", @"ction", @"date", @"adv", @"discover"]);
    dumpClassMethods(@"CBDiscovery", @[]);
    dumpClassMethods(@"CBDiscoverySummary", @[]);
    dumpClassMethods(@"CBDevice", @[@"prox", @"earby", @"adv", @"sleep", @"awake"]);

    // 5. BTMagicPairingSettings (mentioned in bluetoothd)
    dumpClassMethods(@"BTMagicPairingSettings", @[]);

    // 6. List ALL classes whose name matches our patterns of interest
    wp11log(@"==== Searching ALL loaded classes for Nearby/Proximity/Continuity ====");
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0 && numClasses < 50000) {
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        objc_getClassList(classes, numClasses);
        int found = 0;
        for (int i = 0; i < numClasses; i++) {
            const char *cn = class_getName(classes[i]);
            if (cn && (strstr(cn, "Nearby") || strstr(cn, "Proxim") || strstr(cn, "Continuity")
                       || strstr(cn, "NRProx") || strstr(cn, "BTMAdv") || strstr(cn, "RPCompanion"))) {
                wp11log(@"  [CLS] %s", cn);
                found++;
                if (found > 100) break;
            }
        }
        free(classes);
        wp11log(@"  [CLS] (%d classes matched)", found);
    }

    wp11log(@"==== PROXIMITY CLASS DUMP END ====");
}


static void br_notify_cb(CFNotificationCenterRef center, void *observer,
                          CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    wp11log(@" [BRIDGE-MON] 🔔 %@", (__bridge NSString *)name);
}

%ctor {
    @autoreleasepool {
        NSString *processName = [[NSProcessInfo processInfo] processName];
        wp11log(@" === Init v4 dans %@ ===", processName);

        // Vider le log au démarrage de SpringBoard
        if ([processName isEqualToString:@"SpringBoard"]) {
            [@"=== WP11 LOG START ===\n" writeToFile:WP11_LOG_PATH
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        // v7.12: Listen for Bridge darwin notifications to trace MiniHook activity
        if ([processName isEqualToString:@"SpringBoard"]) {
            static const CFNotificationName brNames[] = {
                CFSTR("com.wp11.bridge.ctor"), CFSTR("com.wp11.bridge.ctor_done"),
                CFSTR("com.wp11.bridge.npk_connected_called"),
                CFSTR("com.wp11.bridge.npk_connected_hooked"),
                CFSTR("com.wp11.bridge.npk_sym_not_found"),
                CFSTR("com.wp11.bridge.npk_dlopen_failed"),
                CFSTR("com.wp11.bridge.bps_hooked"),
                CFSTR("com.wp11.bridge.gizmo_unreach_alert_hooked"),
            };
            CFNotificationCenterRef cn = CFNotificationCenterGetDarwinNotifyCenter();
            for (int i = 0; i < 8; i++) {
                CFNotificationCenterAddObserver(cn, NULL, br_notify_cb,
                    brNames[i], NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            }
            wp11log(@" [BRIDGE-MON] listeners armed (8 notifications)");
        }

        wp11log(@"=== Init v6.5 dans %@ ===", processName);

        // Créer un fichier témoin par processus (contourne le sandbox)
        NSString *witness = [NSString stringWithFormat:@"/var/tmp/wp11_%@.txt", processName];
        [@"loaded" writeToFile:witness atomically:YES encoding:NSUTF8StringEncoding error:nil];

        // ===== HOOKS (dans TOUS les processus ciblés) =====
        // v7.11: Skip global NR hooks in NPKCompanionAgent — they break Wallet UI.
        // NPKCompanionAgent ONLY gets hookPassd() for canAddSecureElementPass bypass.
        BOOL isNPKCompanionAgent = [processName isEqualToString:@"NPKCompanionAgent"];
        if (!isNPKCompanionAgent) {
            hookNRVersionInfo();
            hookNRDevice();
            hookUnpairPrevention();
            logUnpairMethods();
        }

        // v6.1 — diag dump des classes proximity (uniquement dans bluetoothd pour limiter le bruit)
        if ([processName isEqualToString:@"bluetoothd"]) {
            dumpProximityClasses();
            // v6.2 — install les hooks de monitoring sur les parsers BLE adv
            hookCBDeviceParsers();
        }

        // v6.9 — PROX hooks DÉSACTIVÉS. Approche Legizmo : ne PAS injecter dans nanoregistryd.
        // Fixer les DONNÉES (CFPreferences + MobileAsset) au lieu de forcer le runtime state.
        // Le drain est fixé par le blocage type=0x00 dans bluetoothd (hookCBDeviceParsers).
        // if ([processName isEqualToString:@"nanoregistryd"]) {
        //     hookProximityStateSpoofing();
        // }

        // v7.2 — Version spoof UNIQUEMENT dans les daemons Watch
        // NE PAS spoofer dans imagent/identityservicesd (casse iMessage registration chez Apple)
        NSArray *watchOnlyDaemons = @[@"nanoregistryd", @"pairedsyncd", @"Bridge",
            @"companionproxyd", @"terminusd", @"nanoregistrylaunchd",
            @"appconduitd", @"nptocompaniond"];
        if ([watchOnlyDaemons containsObject:processName]) {
            hookVersionSpoofing();
        }
        // IDS hooks dans tous les daemons sauf SpringBoard (ne touche pas la version)
        // v7.11: aussi skip in NPKCompanionAgent
        if (![processName isEqualToString:@"SpringBoard"] && !isNPKCompanionAgent) {
            hookIDSService();
        }

        // v7.0 — Hook identityservicesd pour intercepter les protobufs "unhandled" de la Watch
        // (pattern Legizmo: service:account:incomingUnhandledProtobuf:fromID:context:)
        if ([processName isEqualToString:@"identityservicesd"]) {
            wp11log(@" [IDS] Hooking IDSService delegate for unhandled protobufs...");
            // Hook ALL classes that implement the IDSServiceDelegate protocol
            int numClasses = objc_getClassList(NULL, 0);
            if (numClasses > 0 && numClasses < 50000) {
                Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
                objc_getClassList(classes, numClasses);
                int hooked = 0;
                SEL unhandledSel = NSSelectorFromString(@"service:account:incomingUnhandledProtobuf:fromID:context:");
                for (int i = 0; i < numClasses; i++) {
                    if (class_getInstanceMethod(classes[i], unhandledSel)) {
                        const char *cn = class_getName(classes[i]);
                        Method m = class_getInstanceMethod(classes[i], unhandledSel);
                        IMP origIMP = method_getImplementation(m);
                        class_replaceMethod(classes[i], unhandledSel,
                            imp_implementationWithBlock(^(id self, id service, id account, id protobuf, id fromID, id context) {
                                wp11log(@" [IDS] incomingUnhandledProtobuf from %@ service:%@ proto:%@ ctx:%@",
                                        fromID, service, [protobuf class], context);
                                // Call original — let iOS try to handle it
                                ((void(*)(id, SEL, id, id, id, id, id))origIMP)(self, unhandledSel, service, account, protobuf, fromID, context);
                            }),
                            method_getTypeEncoding(m));
                        wp11log(@" [IDS]   hooked %s for incomingUnhandledProtobuf", cn);
                        hooked++;
                    }
                }
                free(classes);

                // Also hook incomingData and incomingMessage for logging
                SEL dataSel = NSSelectorFromString(@"service:account:incomingData:fromID:context:");
                for (int i = 0; i < numClasses; i++) {
                    if (class_getInstanceMethod(classes[i], dataSel)) {
                        // just count, don't hook (too noisy)
                    }
                }
                wp11log(@" [IDS] Total unhandledProtobuf hooks: %d", hooked);
            }
        }

        // PassKit hooks dans passd et SpringBoard
        if ([processName isEqualToString:@"passd"] ||
            [processName isEqualToString:@"SpringBoard"]) {
            hookPassKit();
        }

        // v7.7 — passd-specific Apple Pay bypass (native Apple override keys)
        // v7.8 — also run in SpringBoard + Bridge (wherever injection reaches)
        if ([processName isEqualToString:@"passd"] ||
            [processName isEqualToString:@"SpringBoard"] ||
            [processName isEqualToString:@"Bridge"] ||
            [processName isEqualToString:@"NPKCompanionAgent"]) {
            hookPassd();
        }

        // v7.14: Watch productType spoof — ONLY in passd (safe scope for Apple Pay preflight)
        if ([processName isEqualToString:@"passd"]) {
            hookPassdModelSpoof();
        }

        // v7.10 — hook posix_spawn in xpcproxy (where app spawns actually happen)
        // xpcproxy is injected because /usr/libexec/ matches xpcproxyhook allowed prefix
        if ([processName isEqualToString:@"xpcproxy"]) {
            hookBridgeSpawn();
        }

        // Message relay hooks — imagent + SpringBoard only
        // v7.4 FIX: retiré identityservicesd — IMService/CKSMSRelayAccount classes
        // n'existent pas dans identityservicesd context → objc_msgSend crash au ctor
        if ([processName isEqualToString:@"imagent"] ||
            [processName isEqualToString:@"SpringBoard"]) {
            hookMessageRelay();
        }

        // v7.3 — APSSupport: fix envoi Messages depuis la Watch (inspiré WatchFix)
        // v7.6 DISABLED: APSSupport breaks third-party push notifications (Messenger)
        // User rapport : avant WatchPair Messenger notifs arrivaient sur Watch.
        // Post-APSSupport hook : notifs Messenger bloquées.
        // Root cause : notre force sendProxyIsConnected:YES interfère avec proxy state machine.
        // if ([processName isEqualToString:@"apsd"]) {
        //     hookAPSSupport();
        // }

        // v7.3 — AppsSupport: fix apps Watch absentes (inspiré WatchFix)
        if ([processName isEqualToString:@"appconduitd"] ||
            [processName isEqualToString:@"installd"]) {
            hookAppsSupport();
        }

        // v7.3 — IDS UTun: fix compatibilité tunnel IDS (inspiré WatchFix)
        if ([processName isEqualToString:@"identityservicesd"]) {
            hookIDSUTun();
        }

        // ===== Les étapes suivantes seulement dans SpringBoard =====
        if (![processName isEqualToString:@"SpringBoard"]) {
            wp11log(@" === Init v4 hooks-only pour %@ ===", processName);
            return;
        }

        // ===== 1. CFPREFERENCES =====
        CFStringRef nr = CFSTR("com.apple.NanoRegistry");
        setPref(nr, CFSTR("minPairingCompatibilityVersion"), (__bridge CFNumberRef)@(MIN_COMPAT));
        setPref(nr, CFSTR("maxPairingCompatibilityVersion"), (__bridge CFNumberRef)@(MAX_COMPAT));
        setPref(nr, CFSTR("IOS_PAIRING_EOL_MIN_PAIRING_COMPATIBILITY_VERSION_CHIPIDS"), CFSTR(""));
        setPref(nr, CFSTR("minPairingCompatibilityVersionWithChipID"), (__bridge CFNumberRef)@(MIN_COMPAT));
        CFPreferencesSynchronize(nr, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize(nr, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);

        CFStringRef ps = CFSTR("com.apple.pairedsync");
        setPref(ps, CFSTR("activityTimeout"), (__bridge CFNumberRef)@(60));
        CFPreferencesSynchronize(ps, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

        wp11log(@" CFPreferences patched");

        // ===== 2. PLIST DIRECT =====
        NSString *path = @"/var/mobile/Library/Preferences/com.apple.NanoRegistry.plist";
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!d) d = [NSMutableDictionary dictionary];
        d[@"minPairingCompatibilityVersion"] = @(MIN_COMPAT);
        d[@"maxPairingCompatibilityVersion"] = @(MAX_COMPAT);
        d[@"IOS_PAIRING_EOL_MIN_PAIRING_COMPATIBILITY_VERSION_CHIPIDS"] = @"";
        d[@"minPairingCompatibilityVersionWithChipID"] = @(MIN_COMPAT);
        [d writeToFile:path atomically:YES];

        // ===== 3. NEUTRALISER MOBILEASSET =====
        NSString *assetPath = @"/private/var/MobileAsset/AssetsV2/"
                               "com_apple_MobileAsset_NanoRegistryPairingCompatibilityIndex";
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:assetPath]) {
            NSString *bak = [assetPath stringByAppendingString:@".wp11bak"];
            if (![fm fileExistsAtPath:bak]) {
                [fm moveItemAtPath:assetPath toPath:bak error:nil];
                wp11log(@" MobileAsset neutralized");
            }
        }

        wp11log(@" === Prefs + MobileAsset done ===");

        // ===== 4. INJECTION FORCÉE dans les daemons =====
        // nathanlr n'injecte que dans SpringBoard.
        // On force l'injection de notre dylib dans identityservicesd/imagent
        // en les killant et laissant launchd les relancer avec notre env var.
        //
        // Méthode : on crée un script shell qui :
        // 1. Kill le daemon
        // 2. Utilise launchctl setenv pour injecter DYLD_INSERT_LIBRARIES
        // 3. Launchd relance le daemon avec notre dylib

        // Cross-jailbreak path resolution (rootless = /var/jb/..., roothide = jbroot())
        NSString *dylibPath = [NSString stringWithUTF8String:
            WP11_JBROOT("/Library/MobileSubstrate/DynamicLibraries/WatchPair11.dylib")];

        // Vérifier si le dylib existe aussi dans TweakInject
        if (![[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
            dylibPath = [NSString stringWithUTF8String:
                WP11_JBROOT("/usr/lib/TweakInject/WatchPair11.dylib")];
        }

        // Créer un script d'injection
        NSString *script = [NSString stringWithFormat:
            @"#!/bin/bash\n"
            "export DYLD_INSERT_LIBRARIES=%@\n"
            "killall -9 identityservicesd 2>/dev/null\n"
            "sleep 1\n"
            "killall -9 imagent 2>/dev/null\n"
            "sleep 1\n"
            "killall -9 apsd 2>/dev/null\n"
            "sleep 1\n"
            "killall -9 passd 2>/dev/null\n"
            "sleep 1\n"
            "# Fichier témoin\n"
            "echo 'inject_script_ran' > /var/tmp/wp11_inject_ran.txt\n",
            dylibPath];

        NSString *scriptPath = @"/var/tmp/wp11_inject.sh";
        [script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(scriptPath.fileSystemRepresentation, 0755);

        // Exécuter le script
        pid_t pid;
        const char *argv[] = {"/bin/bash", scriptPath.fileSystemRepresentation, NULL};
        extern char **environ;
        posix_spawn(&pid, "/bin/bash", NULL, NULL, (char *const *)argv, environ);

        wp11log(@" Script d'injection lancé: %@", dylibPath);

        // Méthode alternative: utiliser launchctl setenv
        // Ça définit DYLD_INSERT_LIBRARIES pour TOUS les futurs processus launchd
        const char *launchctlArgv[] = {
            "/bin/launchctl", "setenv",
            "DYLD_INSERT_LIBRARIES", dylibPath.fileSystemRepresentation,
            NULL
        };
        pid_t pid2;
        posix_spawn(&pid2, "/bin/launchctl", NULL, NULL, (char *const *)launchctlArgv, environ);
        int status2;
        waitpid(pid2, &status2, 0);
        wp11log(@" launchctl setenv DYLD_INSERT_LIBRARIES -> %@ (status: %d)", dylibPath, status2);

        // Maintenant kill les daemons pour qu'ils redémarrent avec notre dylib
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                const char *k1[] = {"/usr/bin/killall", "-9", "identityservicesd", NULL};
                pid_t p1; posix_spawn(&p1, "/usr/bin/killall", NULL, NULL, (char *const *)k1, environ);
                waitpid(p1, NULL, 0);

                const char *k2[] = {"/usr/bin/killall", "-9", "imagent", NULL};
                pid_t p2; posix_spawn(&p2, "/usr/bin/killall", NULL, NULL, (char *const *)k2, environ);
                waitpid(p2, NULL, 0);

                const char *k3[] = {"/usr/bin/killall", "-9", "apsd", NULL};
                pid_t p3; posix_spawn(&p3, "/usr/bin/killall", NULL, NULL, (char *const *)k3, environ);
                waitpid(p3, NULL, 0);

                const char *k4[] = {"/usr/bin/killall", "-9", "passd", NULL};
                pid_t p4; posix_spawn(&p4, "/usr/bin/killall", NULL, NULL, (char *const *)k4, environ);
                waitpid(p4, NULL, 0);

                wp11log(@" Daemons IDS+PassKit killés, attente restart avec injection...");
            });

        wp11log(@" === Init v6.0 complete (SpringBoard) ===");
    }
}
