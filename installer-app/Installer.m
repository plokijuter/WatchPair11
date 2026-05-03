#import "Installer.h"
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>

extern char **environ;

// Cross-jailbreak path resolution.
// Under roothide the prefix is randomized per-install (computed at runtime by
// jbroot()), so we cannot use static NSString constants — paths must be
// resolved lazily. Under nathanlr (rootless) jbroot.h is absent and we fall
// back to the static "/var/jb" prefix.
#if __has_include(<roothide.h>)
#  include <roothide.h>
#  define WP11_JBROOT_NS(p) [NSString stringWithUTF8String:jbroot(p)]
#else
#  define WP11_JBROOT_NS(p) (@"/var/jb" p)
#endif

@implementation Installer

#pragma mark - Lazy paths (jbroot-aware)

+ (NSString *)jbPrefix       { return WP11_JBROOT_NS(""); }
+ (NSString *)tweakDylib     { return WP11_JBROOT_NS("/Library/MobileSubstrate/DynamicLibraries/WatchPair11.dylib"); }
+ (NSString *)tweakInject    { return WP11_JBROOT_NS("/usr/lib/TweakInject/WatchPair11.dylib"); }
+ (NSString *)sysBinsPath    { return WP11_JBROOT_NS("/System/Library/SysBins/PassKitCore.framework/passd"); }
+ (NSString *)overridePlist  { return WP11_JBROOT_NS("/Library/LaunchDaemons/com.apple.passd.plist"); }
+ (NSString *)setupScript    { return WP11_JBROOT_NS("/opt/watchpair11/setup-applepay.sh"); }
+ (NSString *)rollbackScript { return WP11_JBROOT_NS("/opt/watchpair11/rollback-applepay.sh"); }
+ (NSString *)sudoBin        { return WP11_JBROOT_NS("/basebins/sudo_spawn_root"); }
+ (NSString *)passdSigned    { return WP11_JBROOT_NS("/opt/watchpair11/passd_signed"); }

#pragma mark - Status

+ (BOOL)fileExists:(NSString *)path {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

+ (BOOL)isTweakInstalled {
    return [self fileExists:[self tweakDylib]] || [self fileExists:[self tweakInject]];
}

+ (BOOL)isApplePayInstalled {
    // Under rootless we expect both the SysBins overlay AND the override plist.
    // Under roothide there is no SysBins overlay — only the override plist + the
    // re-signed passd binary in $JB/opt/watchpair11/.
    BOOL overrideOK = [self fileExists:[self overridePlist]];
#if __has_include(<roothide.h>)
    return overrideOK && [self fileExists:[self passdSigned]];
#else
    return overrideOK && [self fileExists:[self sysBinsPath]];
#endif
}

+ (BOOL)isNathanlrAvailable {
    // Backwards-compat name. Under roothide this means "is the jailbreak environment usable".
    return [self fileExists:[self jbPrefix]] && [self fileExists:[self sudoBin]];
}

+ (NSString *)detectedIOSBuild {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    return d[@"ProductBuildVersion"] ?: @"unknown";
}

#pragma mark - Execute helper

- (int)execAsRoot:(NSString *)cmdline logBlock:(InstallerLogBlock)logBlock {
    NSString *sudoBin = [Installer sudoBin];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:sudoBin]) {
        if (logBlock) logBlock([NSString stringWithFormat:@"  ERR: sudo_spawn_root not found at %@", sudoBin]);
        return -1;
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        if (logBlock) logBlock(@"  ERR: pipe() failed");
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]);

    const char *argv[] = {
        [sudoBin UTF8String],
        "/bin/bash",
        "-c",
        [cmdline UTF8String],
        NULL
    };

    pid_t pid;
    int spawnr = posix_spawn(&pid, [sudoBin UTF8String], &actions, NULL,
                             (char *const *)argv, environ);
    close(pipefd[1]);
    posix_spawn_file_actions_destroy(&actions);

    if (spawnr != 0) {
        if (logBlock) logBlock([NSString stringWithFormat:@"  ERR: posix_spawn failed rc=%d", spawnr]);
        close(pipefd[0]);
        return -1;
    }

    char buf[4096];
    NSMutableString *lineAcc = [NSMutableString string];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf)-1)) > 0) {
        buf[n] = 0;
        [lineAcc appendString:[NSString stringWithUTF8String:buf]];
        while (1) {
            NSRange r = [lineAcc rangeOfString:@"\n"];
            if (r.location == NSNotFound) break;
            NSString *line = [lineAcc substringToIndex:r.location];
            if (logBlock && line.length > 0) logBlock([@"  " stringByAppendingString:line]);
            [lineAcc deleteCharactersInRange:NSMakeRange(0, r.location+1)];
        }
    }
    close(pipefd[0]);
    if (lineAcc.length > 0 && logBlock) logBlock([@"  " stringByAppendingString:lineAcc]);

    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

#pragma mark - Apple Pay setup

- (void)installApplePayWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^L)(NSString *) = ^(NSString *s) {
            dispatch_async(dispatch_get_main_queue(), ^{ log(s); });
        };

        L(@"[Step 1/2] Prerequisites check...");
        if (![Installer isNathanlrAvailable]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"Jailbreak not detected. Re-JB first.");
            });
            return;
        }
        if (![Installer isTweakInstalled]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"WatchPair11 dylib not installed. Reinstall the .deb from Sileo/Cydia/Zebra.");
            });
            return;
        }
        NSString *setupScript = [Installer setupScript];
        if (![Installer fileExists:setupScript]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"Setup script missing : %@", setupScript]);
            });
            return;
        }
        NSString *build = [Installer detectedIOSBuild];
        L([NSString stringWithFormat:@"  iOS build : %@", build]);
        if (![build isEqualToString:@"20G75"]) {
            L([NSString stringWithFormat:@"  ⚠️  Built for 20G75 (iOS 16.6). Your build is %@. Setup may not work — Rollback if needed.", build]);
        }
        L(@"  ✓ All prerequisites met");

        L(@"[Step 2/2] Running setup-applepay.sh...");
        int rc = [self execAsRoot:[NSString stringWithFormat:@"bash %@ </dev/null", setupScript] logBlock:L];
        if (rc != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"Setup script failed (rc=%d). See log + run rollback if device is broken.", rc]);
            });
            return;
        }

        L(@"");
        L(@"✅ Apple Pay setup complete!");
        L(@"NEXT : Reboot your iPhone, then re-JB.");
        L(@"Then : Watch app → Wallet → Add Card → verify with bank.");

        dispatch_async(dispatch_get_main_queue(), ^{
            done(YES, nil);
        });
    });
}

#pragma mark - Rollback

- (void)rollbackApplePayWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^L)(NSString *) = ^(NSString *s) {
            dispatch_async(dispatch_get_main_queue(), ^{ log(s); });
        };

        L(@"[Rollback] Running rollback-applepay.sh...");
        NSString *rollbackScript = [Installer rollbackScript];
        if (![Installer fileExists:rollbackScript]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"Rollback script missing : %@", rollbackScript]);
            });
            return;
        }

        int rc = [self execAsRoot:[NSString stringWithFormat:@"bash %@ </dev/null", rollbackScript] logBlock:L];
        if (rc != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"Rollback failed (rc=%d). Reboot may help.", rc]);
            });
            return;
        }

        L(@"");
        L(@"✅ Apple Pay rolled back. Reboot recommended for clean state.");
        L(@"The pairing tweak is still active — uninstall the .deb to remove it.");

        dispatch_async(dispatch_get_main_queue(), ^{
            done(YES, nil);
        });
    });
}

#pragma mark - System actions

- (void)respringWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^L)(NSString *) = ^(NSString *s) {
            dispatch_async(dispatch_get_main_queue(), ^{ log(s); });
        };
        L(@"[Respring] Killing SpringBoard...");
        // SpringBoard respawns immediately; this app dies because backboardd kills clients
        [self execAsRoot:@"killall -9 SpringBoard 2>/dev/null; true" logBlock:L];
        dispatch_async(dispatch_get_main_queue(), ^{ done(YES, nil); });
    });
}

- (void)userspaceRebootWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^L)(NSString *) = ^(NSString *s) {
            dispatch_async(dispatch_get_main_queue(), ^{ log(s); });
        };
        L(@"[Userspace reboot] launchctl reboot userspace...");
        L(@"⚠️ JB may drop. If apps revert, re-launch your jailbreak loader.");
        [self execAsRoot:@"launchctl reboot userspace 2>&1; true" logBlock:L];
        dispatch_async(dispatch_get_main_queue(), ^{ done(YES, nil); });
    });
}

@end
