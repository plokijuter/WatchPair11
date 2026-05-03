#import <Foundation/Foundation.h>

typedef void (^InstallerLogBlock)(NSString *line);
typedef void (^InstallerDoneBlock)(BOOL success, NSString *error);

@interface Installer : NSObject

// Status detection
+ (BOOL)isTweakInstalled;
+ (BOOL)isApplePayInstalled;
+ (NSString *)detectedIOSBuild;
+ (BOOL)isNathanlrAvailable;

// Apple Pay actions (call system scripts at /var/jb/opt/watchpair11/)
- (void)installApplePayWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;
- (void)rollbackApplePayWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;

// System actions
- (void)respringWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;
- (void)userspaceRebootWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;

@end
