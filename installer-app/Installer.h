#import <Foundation/Foundation.h>

typedef void (^InstallerLogBlock)(NSString *line);
typedef void (^InstallerDoneBlock)(BOOL success, NSString *error);

@interface Installer : NSObject

// Status detection
+ (BOOL)isTweakInstalled;
+ (BOOL)isApplePayInstalled;
+ (NSString *)detectedIOSBuild;
+ (BOOL)isNathanlrAvailable;

// Install actions (async, calls log block for each step)
- (void)installTweakWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;
- (void)installApplePayWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;
- (void)rollbackAllWithLog:(InstallerLogBlock)log done:(InstallerDoneBlock)done;

@end
