#import <Foundation/Foundation.h>

typedef void (^InstallerLogBlock)(NSString *line);
typedef void (^InstallerDoneBlock)(BOOL success, NSString *error);

@interface Installer : NSObject

// Status detection
+ (BOOL)isTweakInstalled;
+ (BOOL)isApplePayInstalled;
+ (NSString *)detectedIOSBuild;
+ (BOOL)isNathanlrAvailable;

// Cross-jailbreak path resolution (rootless = /var/jb/..., roothide = jbroot()).
// All paths below are computed lazily — under roothide the prefix is randomized.
+ (NSString *)jbPrefix;
+ (NSString *)tweakDylib;
+ (NSString *)tweakInject;
+ (NSString *)sysBinsPath;
+ (NSString *)overridePlist;
+ (NSString *)setupScript;
+ (NSString *)rollbackScript;
+ (NSString *)sudoBin;
+ (NSString *)passdSigned;

// Apple Pay actions (call system scripts at jbroot("/opt/watchpair11/"))
- (void)installApplePayWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;
- (void)rollbackApplePayWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;

// System actions
- (void)respringWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;
- (void)userspaceRebootWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;

@end
