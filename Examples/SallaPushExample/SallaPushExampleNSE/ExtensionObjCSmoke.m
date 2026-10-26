// Compile-time check of the Objective-C surface of SallaPushExtension, built with APPLICATION_EXTENSION_API_ONLY:
// every @objc selector is called here, once with real arguments and once with nil for each object parameter.
// The extension never calls this class; building the example is the test.
@import SallaPushExtension;
@import UserNotifications;

@interface SallaPushExtensionObjCSmoke : NSObject
@end

@implementation SallaPushExtensionObjCSmoke

+ (void)handleRequest:(UNNotificationRequest *)request
   withContentHandler:(void (^)(UNNotificationContent *))contentHandler {
    SallaPushServiceExtension *fromInfoPlist = [[SallaPushServiceExtension alloc] init];
    SallaPushServiceExtension *withGroup =
        [[SallaPushServiceExtension alloc] initWithAppGroupIdentifier:@"group.com.salla.push.example"];
    SallaPushServiceExtension *withoutGroup = [[SallaPushServiceExtension alloc] initWithAppGroupIdentifier:nil];

    if (![SallaPushServiceExtension isSallaPushNotification:request]) {
        contentHandler(request.content);
        return;
    }
    if (![fromInfoPlist didReceive:request withContentHandler:contentHandler]) {
        contentHandler(request.content);
    }
    (void)[withGroup serviceExtensionTimeWillExpire];
    (void)[withoutGroup serviceExtensionTimeWillExpire];
    (void)[fromInfoPlist serviceExtensionTimeWillExpire];
}

// Objective-C callers can pass nil where the Swift API takes an object; SallaPush returns NO without calling the
// content handler.
+ (void)callEveryObjectParameterWithNil {
    UNNotificationRequest *noRequest = nil;
    SallaPushServiceExtension *handler = [[SallaPushServiceExtension alloc] init];
    (void)[SallaPushServiceExtension isSallaPushNotification:noRequest];
    (void)[handler didReceive:noRequest withContentHandler:^(UNNotificationContent *content) {
        (void)content;
    }];
}

@end
