#import "Installer.h"
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>

extern char **environ;

static NSString *const kJBPrefix = @"/var/jb";
static NSString *const kTweakDylib = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/WatchPair11.dylib";
static NSString *const kTweakInject = @"/var/jb/usr/lib/TweakInject/WatchPair11.dylib";
static NSString *const kSysBinsPath = @"/var/jb/System/Library/SysBins/PassKitCore.framework/passd";
static NSString *const kOverridePlist = @"/var/jb/Library/LaunchDaemons/com.apple.passd.plist";
static NSString *const kSetupScript = @"/var/jb/opt/watchpair11/setup-applepay.sh";
static NSString *const kRollbackScript = @"/var/jb/opt/watchpair11/rollback-applepay.sh";
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
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        @"/System/Library/CoreServices/SystemVersion.plist"];
    return d[@"ProductBuildVersion"] ?: @"unknown";
}

#pragma mark - Execute helper

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
                done(NO, @"nathanlr jailbreak not detected. Re-JB first.");
            });
            return;
        }
        if (![Installer isTweakInstalled]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, @"WatchPair11 dylib not installed. Reinstall the .deb from Sileo/Cydia/Zebra.");
            });
            return;
        }
        if (![Installer fileExists:kSetupScript]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"Setup script missing : %@", kSetupScript]);
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
        int rc = [self execAsRoot:[NSString stringWithFormat:@"bash %@ </dev/null", kSetupScript] logBlock:L];
        if (rc != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"Setup script failed (rc=%d). See log + run rollback if device is broken.", rc]);
            });
            return;
        }

        L(@"");
        L(@"✅ Apple Pay setup complete!");
        L(@"NEXT : Reboot your iPhone, then re-JB nathanlr.");
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
        if (![Installer fileExists:kRollbackScript]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                done(NO, [NSString stringWithFormat:@"Rollback script missing : %@", kRollbackScript]);
            });
            return;
        }

        int rc = [self execAsRoot:[NSString stringWithFormat:@"bash %@ </dev/null", kRollbackScript] logBlock:L];
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
        L(@"⚠️ JB may drop. If apps revert, re-launch your nathanlr loader.");
        [self execAsRoot:@"launchctl reboot userspace 2>&1; true" logBlock:L];
        dispatch_async(dispatch_get_main_queue(), ^{ done(YES, nil); });
    });
}

@end
