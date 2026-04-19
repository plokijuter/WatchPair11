#import "Installer.h"
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>

extern char **environ;

static NSString *const kJBPrefix = @"/var/jb";
static NSString *const kTweakDylib = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/WatchPair11.dylib";
static NSString *const kTweakPlist = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/WatchPair11.plist";
static NSString *const kTweakInject = @"/var/jb/usr/lib/TweakInject/WatchPair11.dylib";
static NSString *const kSysBinsPath = @"/var/jb/System/Library/SysBins/PassKitCore.framework/passd";
static NSString *const kOverridePlist = @"/var/jb/Library/LaunchDaemons/com.apple.passd.plist";
static NSString *const kPassKitPrefs = @"/var/mobile/Library/Preferences/com.apple.passd.plist";
static NSString *const kSudoBin = @"/var/jb/basebins/sudo_spawn_root";

@implementation Installer

#pragma mark - Status

+ (BOOL)fileExists:(NSString *)path {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

+ (BOOL)isTweakInstalled {
    return [self fileExists:kTweakDylib] || [self fileExists:kTweakInject];
}

+ (BOOL)isApplePayInstalled {
    return [self fileExists:kSysBinsPath] && [self fileExists:kOverridePlist];
}

+ (BOOL)isNathanlrAvailable {
    return [self fileExists:kJBPrefix] && [self fileExists:kSudoBin];
}

+ (NSString *)detectedIOSBuild {
    // Read /System/Library/CoreServices/SystemVersion.plist
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    return d[@"ProductBuildVersion"] ?: @"unknown";
}

#pragma mark - Execute helpers

// Execute a command line via sudo_spawn_root. Captures stdout+stderr, line-by-line to logBlock.
- (int)execAsRoot:(NSString *)cmdline logBlock:(InstallerLogBlock)logBlock {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kSudoBin]) {
        if (logBlock) logBlock([NSString stringWithFormat:@"  ERR: sudo_spawn_root not found at %@", kSudoBin]);
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
        [kSudoBin UTF8String],
        "/bin/bash",
        "-c",
        [cmdline UTF8String],
        NULL
    };

    pid_t pid;
    int spawnr = posix_spawn(&pid, [kSudoBin UTF8String], &actions, NULL,
                             (char *const *)argv, environ);
    close(pipefd[1]);
    posix_spawn_file_actions_destroy(&actions);

    if (spawnr != 0) {
        if (logBlock) logBlock([NSString stringWithFormat:@"  ERR: posix_spawn failed rc=%d", spawnr]);
        close(pipefd[0]);
        return -1;
    }

    // Read output
    char buf[4096];
    NSMutableString *lineAcc = [NSMutableString string];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf)-1)) > 0) {
        buf[n] = 0;
        [lineAcc appendString:[NSString stringWithUTF8String:buf]];
        // Split on newlines
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
    int exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return exit_code;
}

- (NSString *)resourcePath:(NSString *)name {
    return [[NSBundle mainBundle] pathForResource:name ofType:nil];
}

#pragma mark - Install tweak

- (void)installTweakWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^L)(NSString *) = ^(NSString *s) {
            dispatch_async(dispatch_get_main_queue(), ^{ log(s); });
        };

        L(@"[Step 1/3] Checking prerequisites...");
        if (![Installer isNathanlrAvailable]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"nathanlr jailbreak not detected. Re-JB first.");
            });
            return;
        }
        L(@"  ✓ nathanlr found");

        NSString *srcDylib = [self resourcePath:@"WatchPair11.dylib"];
        NSString *srcPlist = [self resourcePath:@"WatchPair11.plist"];
        if (!srcDylib || !srcPlist) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"Missing embedded resources (dylib/plist)");
            });
            return;
        }

        L(@"[Step 2/3] Deploying WatchPair11 dylib + filter...");
        NSString *cmd = [NSString stringWithFormat:
            @"mkdir -p /var/jb/Library/MobileSubstrate/DynamicLibraries && "
             "cp '%@' %@ && "
             "cp '%@' %@ && "
             "mkdir -p /var/jb/usr/lib/TweakInject && "
             "cp '%@' %@ && "
             "chmod 755 %@ %@",
            srcDylib, kTweakDylib,
            srcPlist, kTweakPlist,
            srcDylib, kTweakInject,
            kTweakDylib, kTweakInject];
        int rc = [self execAsRoot:cmd logBlock:L];
        if (rc != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"Deploy failed (rc=%d)", rc]);
            });
            return;
        }
        L(@"  ✓ Dylib + filter plist deployed");

        L(@"[Step 3/3] Killing daemons for reload...");
        [self execAsRoot:@"for d in bluetoothd companionproxyd nptocompaniond terminusd pairedsyncd Bridge imagent appconduitd passd; do killall -9 \"$d\" 2>/dev/null || true; done" logBlock:L];
        L(@"  ✓ Daemons will respawn with tweak loaded");

        L(@"");
        L(@"✅ Tweak installed successfully!");
        L(@"Pairing + notifs will work after re-JB.");
        L(@"");
        L(@"Next step: tap 'Install Apple Pay' for payment support.");

        dispatch_async(dispatch_get_main_queue(), ^{
            done(YES, nil);
        });
    });
}

#pragma mark - Install Apple Pay

- (void)installApplePayWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^L)(NSString *) = ^(NSString *s) {
            dispatch_async(dispatch_get_main_queue(), ^{ log(s); });
        };

        L(@"[Step 1/5] Prerequisites check...");
        if (![Installer isTweakInstalled]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"Tweak not installed. Run 'Install Tweak' first.");
            });
            return;
        }
        NSString *build = [Installer detectedIOSBuild];
        L([NSString stringWithFormat:@"  iOS build detected: %@", build]);
        if (![build isEqualToString:@"20G75"]) {
            L([NSString stringWithFormat:@"  ⚠️  Built for 20G75 (iOS 16.6). Your build is %@.", build]);
            L(@"  Continuing — may not work. If it fails, use Rollback.");
        }

        NSString *srcPassd = [self resourcePath:@"passd_signed"];
        NSString *srcOverride = [self resourcePath:@"com.apple.passd.plist"];
        if (!srcPassd || !srcOverride) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"Missing Apple Pay resources in bundle");
            });
            return;
        }

        L(@"[Step 2/5] Backup current state...");
        [self execAsRoot:@"mkdir -p /var/jb/opt/watchpair11/backup && "
                         "[ -f /var/jb/Library/LaunchDaemons/com.apple.passd.plist ] && cp /var/jb/Library/LaunchDaemons/com.apple.passd.plist /var/jb/opt/watchpair11/backup/override.plist.bak 2>/dev/null || true; "
                         "[ -f /var/mobile/Library/Preferences/com.apple.passd.plist ] && cp /var/mobile/Library/Preferences/com.apple.passd.plist /var/jb/opt/watchpair11/backup/passkit_prefs.bak 2>/dev/null || true; "
                         "true"
                logBlock:L];
        L(@"  ✓ Backup stored in /var/jb/opt/watchpair11/backup/");

        L(@"[Step 3/5] Deploy passd SysBins...");
        NSString *cmd3 = [NSString stringWithFormat:
            @"mkdir -p /var/jb/System/Library/SysBins/PassKitCore.framework && "
             "cp '%@' %@ && "
             "chmod 755 %@ && "
             "cp '%@' %@",
            srcPassd, kSysBinsPath,
            kSysBinsPath,
            srcOverride, kOverridePlist];
        int rc3 = [self execAsRoot:cmd3 logBlock:L];
        if (rc3 != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"SysBins deploy failed (rc=%d)", rc3]);
            });
            return;
        }
        L(@"  ✓ passd + override plist deployed");

        L(@"[Step 4/5] Writing PassKit preferences (8 keys)...");
        // Use plutil if available, otherwise fallback
        NSString *cmd4 =
          @"PREFS=/var/mobile/Library/Preferences/com.apple.passd.plist; "
           "if command -v plutil >/dev/null 2>&1 && [ -f \"$PREFS\" ]; then "
           "  for k in PKIsUserPropertyOverrideEnabled PKBypassCertValidation PKBypassStockholmRegionCheck PKBypassImmoTokenCountCheck PKDeveloperLoggingEnabled PKShowFakeRemoteCredentials; do "
           "    plutil -replace \"$k\" -bool true \"$PREFS\" 2>/dev/null || true; "
           "  done; "
           "  plutil -replace PKClientHTTPHeaderHardwarePlatformOverride -string 'iPhone15,3' \"$PREFS\" 2>/dev/null || true; "
           "  plutil -replace PKClientHTTPHeaderOSPartOverride -string 'iPhone OS 17.0' \"$PREFS\" 2>/dev/null || true; "
           "  echo 'Prefs updated via plutil'; "
           "else "
           "  echo 'plutil not available, writing minimal prefs'; "
           "  cat > \"$PREFS\" <<'EOF'\n"
           "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
           "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
           "<plist version=\"1.0\"><dict>"
           "<key>PKIsUserPropertyOverrideEnabled</key><true/>"
           "<key>PKBypassCertValidation</key><true/>"
           "<key>PKBypassStockholmRegionCheck</key><true/>"
           "<key>PKBypassImmoTokenCountCheck</key><true/>"
           "<key>PKDeveloperLoggingEnabled</key><true/>"
           "<key>PKShowFakeRemoteCredentials</key><true/>"
           "<key>PKClientHTTPHeaderHardwarePlatformOverride</key><string>iPhone15,3</string>"
           "<key>PKClientHTTPHeaderOSPartOverride</key><string>iPhone OS 17.0</string>"
           "</dict></plist>\n"
           "EOF\n"
           "fi; "
           "chown mobile:mobile \"$PREFS\" 2>/dev/null || true; "
           "killall -HUP cfprefsd 2>/dev/null || true";
        [self execAsRoot:cmd4 logBlock:L];
        L(@"  ✓ PassKit prefs written");

        L(@"[Step 5/5] Reload launchd services...");
        [self execAsRoot:
          @"launchctl unload /System/Library/LaunchDaemons/com.apple.passd.plist 2>/dev/null || true; "
           "launchctl load /var/jb/Library/LaunchDaemons/com.apple.passd.plist 2>/dev/null || true; "
           "killall -9 passd 2>/dev/null || true; "
           "sleep 2; "
           "launchctl kickstart -k system/com.apple.passd 2>/dev/null || true"
          logBlock:L];
        L(@"  ✓ Services reloaded");

        L(@"");
        L(@"✅ Apple Pay installed!");
        L(@"");
        L(@"IMPORTANT: Reboot + re-JB nathanlr to activate fully.");
        L(@"Then: Watch app → Wallet → Add Card → verify with bank.");

        dispatch_async(dispatch_get_main_queue(), ^{
            done(YES, nil);
        });
    });
}

#pragma mark - Rollback

- (void)rollbackAllWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void (^L)(NSString *) = ^(NSString *s) {
            dispatch_async(dispatch_get_main_queue(), ^{ log(s); });
        };

        L(@"[Rollback] Removing Apple Pay setup...");
        [self execAsRoot:
          @"launchctl unload /var/jb/Library/LaunchDaemons/com.apple.passd.plist 2>/dev/null || true; "
           "rm -f /var/jb/Library/LaunchDaemons/com.apple.passd.plist; "
           "rm -rf /var/jb/System/Library/SysBins/PassKitCore.framework; "
           "launchctl load /System/Library/LaunchDaemons/com.apple.passd.plist 2>/dev/null || true; "
           "if [ -f /var/jb/opt/watchpair11/backup/passkit_prefs.bak ]; then "
           "  cp /var/jb/opt/watchpair11/backup/passkit_prefs.bak /var/mobile/Library/Preferences/com.apple.passd.plist; "
           "  chown mobile:mobile /var/mobile/Library/Preferences/com.apple.passd.plist; "
           "  echo 'PassKit prefs restored from backup'; "
           "else "
           "  for k in PKIsUserPropertyOverrideEnabled PKBypassCertValidation PKBypassStockholmRegionCheck PKBypassImmoTokenCountCheck PKDeveloperLoggingEnabled PKShowFakeRemoteCredentials PKClientHTTPHeaderHardwarePlatformOverride PKClientHTTPHeaderOSPartOverride; do "
           "    plutil -remove \"$k\" /var/mobile/Library/Preferences/com.apple.passd.plist 2>/dev/null || true; "
           "  done; "
           "  echo 'PassKit override keys removed'; "
           "fi; "
           "killall -HUP cfprefsd 2>/dev/null || true; "
           "killall -9 passd 2>/dev/null || true"
          logBlock:L];
        L(@"  ✓ Apple Pay rolled back");

        L(@"[Rollback] Disabling tweak (keeping .deb installed)...");
        [self execAsRoot:
          @"[ -f /var/jb/Library/MobileSubstrate/DynamicLibraries/WatchPair11.dylib ] && "
           "  mv /var/jb/Library/MobileSubstrate/DynamicLibraries/WatchPair11.dylib{,.disabled}; "
           "[ -f /var/jb/usr/lib/TweakInject/WatchPair11.dylib ] && "
           "  mv /var/jb/usr/lib/TweakInject/WatchPair11.dylib{,.disabled}; "
           "true"
          logBlock:L];
        L(@"  ✓ Tweak disabled (renamed to .disabled)");

        L(@"");
        L(@"✅ Rollback complete.");
        L(@"Reboot recommended for clean state.");

        dispatch_async(dispatch_get_main_queue(), ^{
            done(YES, nil);
        });
    });
}

@end
