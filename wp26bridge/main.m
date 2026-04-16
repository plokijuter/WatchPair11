// WP26Bridge — Alloy topic bridge daemon
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

static void wp26log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss.SSS"];
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@][wp26bridge] %@\n", ts, msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/tmp/wp26bridge.log"];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:@"/var/tmp/wp26bridge.log" contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/tmp/wp26bridge.log"];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    NSLog(@"[wp26bridge] %@", msg);
}

// IDSServiceDelegate methods we implement
@interface WP26AlloyBridge : NSObject
@end

@implementation WP26AlloyBridge

- (void)service:(id)service account:(id)account incomingMessage:(id)message fromID:(id)fromID context:(id)context {
    wp26log(@"incomingMessage from %@ service:%@ msg:%@", fromID, service, message);
}

- (void)service:(id)service account:(id)account incomingData:(id)data fromID:(id)fromID context:(id)context {
    wp26log(@"incomingData from %@ service:%@ len:%lu", fromID, service, (unsigned long)[data length]);
}

- (void)service:(id)service account:(id)account incomingUnhandledProtobuf:(id)protobuf fromID:(id)fromID context:(id)context {
    wp26log(@"incomingUnhandledProtobuf from %@ service:%@ proto:%@ ctx:%@",
            fromID, service, [protobuf class], context);
}

- (void)service:(id)service account:(id)account incomingResourceAtURL:(id)url metadata:(id)metadata fromID:(id)fromID context:(id)context {
    wp26log(@"incomingResource from %@ service:%@ url:%@", fromID, service, url);
}

- (void)service:(id)service didSwitchActivePairedDevice:(id)device acknowledgementBlock:(id)block {
    wp26log(@"didSwitchActivePairedDevice: %@", device);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        wp26log(@"=== WP26Bridge starting ===");

        // Load IDS framework
        void *ids = dlopen("/System/Library/PrivateFrameworks/IDS.framework/IDS", RTLD_LAZY);
        if (!ids) {
            wp26log(@"ERROR: Failed to load IDS.framework: %s", dlerror());
            return 1;
        }
        wp26log(@"IDS.framework loaded");

        // Get IDSService class
        Class IDSServiceClass = NSClassFromString(@"IDSService");
        if (!IDSServiceClass) {
            wp26log(@"ERROR: IDSService class not found");
            return 1;
        }

        WP26AlloyBridge *bridge = [[WP26AlloyBridge alloc] init];

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
                        wp26log(@"Registered for topic: %@", topic);
                    } else {
                        wp26log(@"WARNING: service %@ doesn't respond to addDelegate:queue:", topic);
                    }
                } else {
                    wp26log(@"WARNING: Failed to init IDSService for %@", topic);
                }
            } @catch (NSException *e) {
                wp26log(@"ERROR registering %@: %@", topic, e);
            }
        }

        wp26log(@"=== WP26Bridge ready, entering run loop ===");
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
