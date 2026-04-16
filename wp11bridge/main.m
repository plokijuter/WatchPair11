// WP11Bridge — Alloy topic bridge daemon
// Registers for IDS Alloy topics that identityservicesd on iOS 16 refuses
// to route for watchOS 11.5, and forwards them to the appropriate handlers.
//
// Approach inspired by Legizmo's LegizmoThemis XPC service architecture.
// Instead of injecting into identityservicesd, we run alongside it and
// register as an IDS service delegate for the missing Alloy topics.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// IDS framework — loaded dynamically
// IDSService, IDSServiceDelegate protocol

static void wp11log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss.SSS"];
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@][wp11bridge] %@\n", ts, msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/tmp/wp11bridge.log"];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:@"/var/tmp/wp11bridge.log" contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/tmp/wp11bridge.log"];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    NSLog(@"[wp11bridge] %@", msg);
}

// IDSServiceDelegate methods we implement
@interface WP11AlloyBridge : NSObject
@end

@implementation WP11AlloyBridge

- (void)service:(id)service account:(id)account incomingMessage:(id)message fromID:(id)fromID context:(id)context {
    wp11log(@"incomingMessage from %@ service:%@ msg:%@", fromID, service, message);
}

- (void)service:(id)service account:(id)account incomingData:(id)data fromID:(id)fromID context:(id)context {
    wp11log(@"incomingData from %@ service:%@ len:%lu", fromID, service, (unsigned long)[data length]);
}

- (void)service:(id)service account:(id)account incomingUnhandledProtobuf:(id)protobuf fromID:(id)fromID context:(id)context {
    wp11log(@"incomingUnhandledProtobuf from %@ service:%@ proto:%@ ctx:%@",
            fromID, service, [protobuf class], context);
}

- (void)service:(id)service account:(id)account incomingResourceAtURL:(id)url metadata:(id)metadata fromID:(id)fromID context:(id)context {
    wp11log(@"incomingResource from %@ service:%@ url:%@", fromID, service, url);
}

- (void)service:(id)service didSwitchActivePairedDevice:(id)device acknowledgementBlock:(id)block {
    wp11log(@"didSwitchActivePairedDevice: %@", device);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        wp11log(@"=== WP11Bridge starting ===");

        // Load IDS framework
        void *ids = dlopen("/System/Library/PrivateFrameworks/IDS.framework/IDS", RTLD_LAZY);
        if (!ids) {
            wp11log(@"ERROR: Failed to load IDS.framework: %s", dlerror());
            return 1;
        }
        wp11log(@"IDS.framework loaded");

        // Get IDSService class
        Class IDSServiceClass = NSClassFromString(@"IDSService");
        if (!IDSServiceClass) {
            wp11log(@"ERROR: IDSService class not found");
            return 1;
        }

        WP11AlloyBridge *bridge = [[WP11AlloyBridge alloc] init];

        // Alloy topics we want to register for
        NSArray *topics = @[
            @"com.apple.private.alloy.bulletindistributor",
            @"com.apple.private.alloy.bulletindistributor.settings",
            @"com.apple.private.alloy.messages",
            @"com.apple.private.alloy.quickboard.classa",
        ];

        for (NSString *topic in topics) {
            @try {
                // IDSService initWithService:
                SEL initSel = NSSelectorFromString(@"initWithService:");
                id service = ((id(*)(id,SEL,id))objc_msgSend)([IDSServiceClass alloc], initSel, topic);
                if (service) {
                    // setDelegate:queue:
                    SEL addDel = NSSelectorFromString(@"addDelegate:queue:");
                    if ([service respondsToSelector:addDel]) {
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                            [service methodSignatureForSelector:addDel]];
                        [inv setSelector:addDel];
                        [inv setTarget:service];
                        id del = bridge;
                        dispatch_queue_t q = dispatch_get_main_queue();
                        [inv setArgument:&del atIndex:2];
                        [inv setArgument:&q atIndex:3];
                        [inv invoke];
                        wp11log(@"Registered for topic: %@", topic);
                    } else {
                        wp11log(@"WARNING: service %@ doesn't respond to addDelegate:queue:", topic);
                    }
                } else {
                    wp11log(@"WARNING: Failed to init IDSService for %@", topic);
                }
            } @catch (NSException *e) {
                wp11log(@"ERROR registering %@: %@", topic, e);
            }
        }

        wp11log(@"=== WP11Bridge ready, entering run loop ===");
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
